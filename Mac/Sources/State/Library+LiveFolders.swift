import Foundation
import AppKit
import SwiftUI
import BrowserCore
import BrowserEngine
import Suggest

/// The feed a page lists in its head, and the name to give its folder.
struct PageFeed: Equatable {
    let url: URL
    let name: String
}

/// Live Folders: pinned folders that fill themselves from a feed or your GitHub pull requests (see
/// `LiveFolders` for the rules). Each item is an ordinary pinned tab inside the folder, so opening,
/// moving and unloading work as they do for any pinned tab. You turn them on rather than build
/// them: Pull Requests from the Library or the Command Bar, a site from its own page ("Follow in
/// Sidebar", offered only where the page lists a feed) or by its address in the Library.
/// GitHub folders check every 2 minutes while Browsa is in front; feeds every 15 minutes.
extension Library {
    /// How often the loop wakes. GitHub folders check this often while Browsa is in front (Dia's
    /// 2 minutes); feeds every 15 minutes.
    static let liveTick: Duration = .seconds(120)
    static let feedInterval: TimeInterval = 15 * 60

    nonisolated static let liveFoldersKey = "liveFolders.on"

    /// Starts the checks. Called once, from `init`.
    func startLiveFolders() {
        // Live folders made before the Library switch existed: it starts on for them.
        if UserDefaults.standard.object(forKey: Self.liveFoldersKey) == nil,
           regularSpaces.contains(where: { !LiveFolders.liveFolders(in: $0.pinnedTree).isEmpty }) {
            liveFoldersOn = true
        }
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            await self?.refreshAllLiveFolders(dueOnly: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: Library.liveTick)
                await self?.refreshAllLiveFolders(dueOnly: true)
            }
        }
        // A window coming forward checks GitHub folders that are due, as Dia does.
        liveFocusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshAllLiveFolders(dueOnly: true) }
        }
        updateLiveUnread()
    }

    /// `dueOnly`: feeds that checked within 15 minutes, and GitHub folders within 2 (or while
    /// Browsa is in the background), wait.
    func refreshAllLiveFolders(dueOnly: Bool = false) async {
        guard liveFoldersOn else { return }
        for space in regularSpaces {
            for folder in LiveFolders.liveFolders(in: space.pinnedTree) {
                guard let live = folder.live else { continue }
                if dueOnly {
                    let age = live.lastChecked.map { Date.now.timeIntervalSince($0) } ?? .infinity
                    if live.kind.usesGitHubLogin {
                        guard NSApp.isActive, age >= 110 else { continue }
                    } else if age < Self.feedInterval { continue }
                }
                await refreshLiveFolder(folder.id, in: space)
            }
        }
    }

    /// A new live folder at the top of the space's pinned tabs. It fills in a moment later.
    @discardableResult
    func newLiveFolder(_ kind: LiveSourceKind, name: String, in space: Space) -> UUID? {
        guard !space.isPrivate else { return nil }
        // One GitHub folder per space: asking again shows the one it has.
        if kind == .githubPullRequests, let existing = gitHubFolder(in: space) { return existing.id }
        let folder = PinnedFolder(name: name, isOpen: true, live: LiveSource(kind: kind))
        setPinnedLayout(PinnedOutline.inserting(.folder(folder), at: PinnedPlace(parent: nil, index: 0), in: space.pinnedTree), in: space)
        Task { await refreshLiveFolder(folder.id, in: space) }
        return folder.id
    }

    /// Takes a live folder away with the tabs it filled in. Tabs you put in it yourself stay pinned.
    func removeLiveFolder(_ id: UUID, in space: Space) {
        guard let live = PinnedOutline.folder(id, in: space.pinnedTree)?.live else {
            removePinnedFolder(id, in: space)
            return
        }
        removeLiveTabs(live.items.map(\.tabID), in: space)
        setPinnedLayout(PinnedOutline.dissolving(id, in: space.pinnedTree), in: space)
    }

    func markAllLiveRead(_ id: UUID, in space: Space) {
        setPinnedLayout(PinnedOutline.updating(id, in: space.pinnedTree) { f in
            guard var live = f.live else { return }
            for i in live.items.indices { live.items[i].unread = false }
            f.live = live
        }, in: space)
    }

    /// Opening a live item's tab takes its "new" mark off.
    func markLiveItemRead(_ tab: BrowserTab) {
        guard tab.isPinned, liveUnread.contains(tab.id), let space = space(containing: tab) else { return }
        var tree = space.pinnedTree
        for folder in LiveFolders.liveFolders(in: tree) {
            guard let live = folder.live, let read = LiveFolders.markingRead(tab.id, in: live) else { continue }
            tree = PinnedOutline.updating(folder.id, in: tree) { $0.live = read }
        }
        setPinnedLayout(tree, in: space)
    }

    /// Checks a live folder's source and brings the folder up to date.
    func refreshLiveFolder(_ id: UUID, in space: Space) async {
        guard liveFoldersOn, !liveRefreshing.contains(id), let kind = PinnedOutline.folder(id, in: space.pinnedTree)?.live?.kind else { return }
        liveRefreshing.insert(id)
        defer { liveRefreshing.remove(id) }
        // GitHub is read as you: the space's own github.com login goes along, as in a tab.
        var cookies: [String: String] = [:]
        if kind.usesGitHubLogin {
            let jar = await engine.cookies(for: profile(for: space), url: URL(string: "https://github.com/pulls")!)
            cookies = HTTPCookie.requestHeaderFields(with: jar)
        }
        let result = await Self.fetchLive(kind, cookies: cookies, pullQueries: GitHubPulls.queries(for: gitHubFilters))
        // The folder may have changed (or gone) while that was in flight.
        guard let folder = PinnedOutline.folder(id, in: space.pinnedTree), let live = folder.live, live.kind == kind else { return }
        switch result {
        case .failure(let error):
            setPinnedLayout(PinnedOutline.updating(id, in: space.pinnedTree) { f in
                f.live?.lastError = error.message
                f.live?.lastChecked = .now
            }, in: space)
        case .success(let fetched):
            apply(LiveFolders.plan(live, fetched: fetched,
                                   inFolder: Set(PinnedOutline.tabIDs(folder.children)),
                                   keep: Set(windows.flatMap(\.shownTabIDs))),
                  to: id, in: space)
        }
    }

    /// Refreshes a live folder you've just opened, if it hasn't checked in a few minutes.
    func refreshLiveFolderIfStale(_ id: UUID, in space: Space) {
        guard let live = PinnedOutline.folder(id, in: space.pinnedTree)?.live else { return }
        if let last = live.lastChecked, Date.now.timeIntervalSince(last) < 120 { return }
        Task { await refreshLiveFolder(id, in: space) }
    }

    private func apply(_ plan: LivePlan, to id: UUID, in space: Space) {
        removeLiveTabs(plan.removed, in: space)
        // The layout before the new tabs are pinned, so they don't first land at the top level.
        var tree = space.pinnedTree
        for item in plan.added {
            let tab = BrowserTab(id: item.tabID, url: item.url, title: item.title, isPinned: true, lastActive: .distantPast)
            tab.customTitle = item.title
            space.pinned.append(tab)
        }
        // New tabs go where the source lists them: the folder's items in the source's order, with
        // anything you put in the folder yourself kept where it was, after them.
        let itemIDs = plan.source.items.map(\.tabID)
        tree = PinnedOutline.updating(id, in: tree) { f in
            f.live = plan.source
            let mine = f.children.filter { node in
                if case .tab(let t) = node { return !itemIDs.contains(t) && !plan.removed.contains(t) }
                return true
            }
            f.children = itemIDs.map { .tab($0) } + mine
        }
        // Titles the source changed (a renamed pull request).
        for item in plan.source.items {
            if let tab = space.pinned.first(where: { $0.id == item.tabID }), tab.customTitle != item.title,
               plan.added.contains(where: { $0.tabID == item.tabID }) == false {
                tab.customTitle = item.title
            }
        }
        setPinnedLayout(tree, in: space)
    }

    /// Unpins and closes the tabs of items that have gone.
    private func removeLiveTabs(_ ids: [UUID], in space: Space) {
        guard !ids.isEmpty else { return }
        for id in ids {
            guard let tab = space.pinned.first(where: { $0.id == id }) else { continue }
            for w in windows where w.shownTabIDs.contains(id) { w.moveOff(tab, in: space) }
            space.pinned.removeAll { $0.id == id }
            if space.selectedTabID == id { space.selectedTabID = nil }
            unload(id)
        }
        scheduleSave()
    }

    // MARK: GitHub folder

    /// The space's GitHub pull requests folder, if it has one.
    func gitHubFolder(in space: Space) -> PinnedFolder? {
        LiveFolders.liveFolders(in: space.pinnedTree).first { $0.live?.kind == .githubPullRequests }
    }

    /// The Library's switch. On brings Pull Requests to the space (the one Live Folder that's on to
    /// start). Off takes away the Pull Requests folders; sites you follow keep their folders, which
    /// stop updating until it's back on.
    func setLiveFolders(_ on: Bool, in space: Space) {
        guard on != liveFoldersOn else { return }
        liveFoldersOn = on
        if on {
            setPullRequests(true, in: space)
            Task { await refreshAllLiveFolders(dueOnly: false) }
        } else {
            for s in regularSpaces { setPullRequests(false, in: s) }
            pageFeeds = [:]
        }
    }

    /// Turns the space's Pull Requests folder on or off. Off takes it away with its items.
    func setPullRequests(_ on: Bool, in space: Space) {
        if on {
            if gitHubFolder(in: space) == nil { newLiveFolder(.githubPullRequests, name: "Pull Requests", in: space) }
        } else if let folder = gitHubFolder(in: space) {
            removeLiveFolder(folder.id, in: space)
        }
    }

    nonisolated static let gitHubFiltersKey = "liveFolders.gitHubFilters"

    nonisolated static func savedGitHubFilters() -> Set<GitHubPulls.Filter> {
        guard let saved = UserDefaults.standard.stringArray(forKey: gitHubFiltersKey) else { return Set(GitHubPulls.Filter.allCases) }
        let filters = Set(saved.compactMap(GitHubPulls.Filter.init(rawValue:)))
        return filters.isEmpty ? Set(GitHubPulls.Filter.allCases) : filters
    }

    /// Shows or hides one kind of pull request in every Pull Requests folder, straight away. The
    /// last one stays on: a folder that shows nothing would just look broken.
    func setGitHubFilter(_ filter: GitHubPulls.Filter, on: Bool) {
        var next = gitHubFilters
        if on { next.insert(filter) } else { next.remove(filter) }
        guard !next.isEmpty, next != gitHubFilters else { return }
        gitHubFilters = next
        for space in regularSpaces {
            guard let folder = gitHubFolder(in: space) else { continue }
            Task { await refreshLiveFolder(folder.id, in: space) }
        }
    }

    // MARK: Following a site

    /// The space's folder for a feed, if it follows it already.
    func feedFolder(_ url: URL, in space: Space) -> PinnedFolder? {
        LiveFolders.liveFolders(in: space.pinnedTree).first { $0.live?.kind == .feed(url: url) }
    }

    /// Every site followed, across spaces, for the Library.
    var followedSites: [(folder: PinnedFolder, space: Space, url: URL)] {
        regularSpaces.flatMap { space in
            LiveFolders.liveFolders(in: space.pinnedTree).compactMap { folder in
                if case .feed(let url)? = folder.live?.kind { return (folder, space, url) }
                return nil
            }
        }
    }

    /// A page finished loading: notes the feed its head lists, if any. Reads only what the page
    /// already has, so it costs nothing on the network.
    func detectPageFeed(_ page: any EnginePage, url: URL, in tab: BrowserTab) async {
        guard liveFoldersOn, !tab.isPrivate, url.scheme == "https" || url.scheme == "http" else {
            pageFeeds[tab.id] = nil
            return
        }
        var found: PageFeed?
        if let raw = try? await page.evaluate(FeedDiscovery.pageScript, inWorld: "browsa.feeds") as? [Any],
           raw.count == 2, let href = raw[0] as? String, let feed = URL(string: href),
           feed.scheme == "https" || feed.scheme == "http" {
            let name = (raw[1] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            found = PageFeed(url: feed, name: name.isEmpty ? URLNormalizer.displayHost(url) : String(name.prefix(40)))
        }
        if pageFeeds[tab.id] != found { pageFeeds[tab.id] = found }
    }

    /// Follows a feed in a space's sidebar: a folder at the top that fills with its latest posts.
    /// Following it again shows the folder it has.
    @discardableResult
    func follow(_ feed: PageFeed, in space: Space, toastIn browser: Browser? = nil) -> UUID? {
        if let existing = feedFolder(feed.url, in: space) {
            setPinnedFolder(existing.id, open: true, in: space)
            browser?.showToast("Already following \(existing.name)")
            return existing.id
        }
        guard let id = withAnimation(Motion.snappy, { newLiveFolder(.feed(url: feed.url), name: feed.name, in: space) }) else { return nil }
        browser?.showToast("Following \(feed.name)", actions: [
            ToastAction(title: "Undo") { [weak self] in
                withAnimation(Motion.snappy) { self?.removeLiveFolder(id, in: space) }
            },
        ])
        return id
    }

    /// For the Library's "Follow a Site": an address you type, or a page's. Returns a problem to
    /// show, or nil once it's followed.
    func followSite(_ address: String, in space: Space) async -> String? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host() != nil else { return "That doesn't look like a web address." }
        guard let found = await Self.resolveFeed(url) else {
            return "\(URLNormalizer.displayHost(url)) doesn't have a feed to follow."
        }
        let name = found.title.trimmingCharacters(in: .whitespacesAndNewlines)
        follow(PageFeed(url: found.url, name: name.isEmpty ? URLNormalizer.displayHost(url) : String(name.prefix(40))), in: space)
        return nil
    }

    /// The folder's items as a Markdown list, for pasting into notes or a chat.
    func copyLinksAsMarkdown(_ folder: PinnedFolder, in space: Space) {
        let tabs = PinnedOutline.tabIDs(folder.children).compactMap { id in space.pinned.first { $0.id == id } }
        let lines = tabs.compactMap { tab in tab.url.map { "- [\(tab.displayTitle)](\($0.absoluteString))" } }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// A page finished loading. On github.com: offer the GitHub folder once, and check the space's
    /// GitHub folders soon after you open or review a pull request (as Dia does), so it shows up
    /// without waiting for the next check.
    func liveFolderPageFinished(_ url: URL, in tab: BrowserTab) {
        guard liveFoldersOn, !tab.isPrivate, url.host()?.lowercased() == "github.com", let space = space(containing: tab), !space.isPrivate else { return }
        let path = url.path()
        let isPull = GitHubPulls.pullPath(path) != nil
        if isPull, url.fragment()?.hasPrefix("pullrequestreview-") == true || lastGitHubPage[tab.id]?.contains("/compare") == true {
            for folder in LiveFolders.liveFolders(in: space.pinnedTree) where folder.live?.kind.usesGitHubLogin == true {
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    await refreshLiveFolder(folder.id, in: space)
                }
            }
        }
        lastGitHubPage[tab.id] = path
        makeGitHubFolderIfWanted(in: space, from: tab)
    }

    /// Logins that have had their GitHub folder made for them, so removing it keeps it gone (it
    /// comes back from the Library or the Command Bar).
    private static let gitHubAutoKey = "liveFolders.gitHubFolderMadeForProfiles"

    private static func profileKey(_ profile: BrowsingProfile) -> String {
        switch profile {
        case .persistent(let id): "profile-" + id.uuidString
        default: "default"
        }
    }

    /// As Arc felt: the first time a space is signed in on github.com and you have open pull requests
    /// or review requests, its "Pull Requests" folder appears, with an Undo.
    private func makeGitHubFolderIfWanted(in space: Space, from tab: BrowserTab) {
        // Once per GitHub login (a profile), not per space: spaces that share a profile share the
        // account, so a second space would only get a copy of the same folder.
        let key = Self.profileKey(profile(for: space))
        let done = UserDefaults.standard.stringArray(forKey: Self.gitHubAutoKey) ?? []
        let hasOne = regularSpaces.contains { Self.profileKey(profile(for: $0)) == key && gitHubFolder(in: $0) != nil }
        guard !done.contains(key), !hasOne, !gitHubAutoChecking else { return }
        // No open pull requests last time: look again in a while, not on every page.
        if let last = gitHubAutoLastCheck[space.id], Date.now.timeIntervalSince(last) < 10 * 60 { return }
        gitHubAutoLastCheck[space.id] = .now
        gitHubAutoChecking = true
        Task {
            defer { gitHubAutoChecking = false }
            let jar = await engine.cookies(for: profile(for: space), url: URL(string: "https://github.com/pulls")!)
            let header = HTTPCookie.requestHeaderFields(with: jar)
            guard case .success(let items)? = try? await Self.fetchGitHubPulls(GitHubPulls.queries(for: gitHubFilters), cookies: header),
                  !items.isEmpty, gitHubFolder(in: space) == nil else { return }
            UserDefaults.standard.set(done + [key], forKey: Self.gitHubAutoKey)
            withAnimation(Motion.snappy) { _ = newLiveFolder(.githubPullRequests, name: "Pull Requests", in: space) }
            window(showing: tab)?.showToast("Your pull requests are in the sidebar", actions: [
                ToastAction(title: "Undo") { [weak self] in
                    guard let self, let folder = self.gitHubFolder(in: space) else { return }
                    withAnimation(Motion.snappy) { self.removeLiveFolder(folder.id, in: space) }
                },
            ])
        }
    }

    /// Keeps `liveUnread` (the tabs that show a "new" dot) in step with the folders.
    func updateLiveUnread() {
        let ids = Set(regularSpaces.flatMap { space in
            LiveFolders.liveFolders(in: space.pinnedLayout).flatMap { $0.live?.items.filter(\.unread).map(\.tabID) ?? [] }
        })
        if ids != liveUnread { liveUnread = ids }
    }

    // MARK: Fetching

    struct LiveError: Error {
        let message: String
    }

    /// A session that keeps no cookies of its own: the space's are handed in per request, and only ever
    /// to the site they belong to (`SameSiteRedirects`). Feeds use it too, so a feed can't leave a cookie
    /// to see on every check.
    nonisolated static let liveSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c, delegate: SameSiteRedirects(), delegateQueue: nil)
    }()

    /// A redirect to another host goes without the Cookie and Authorization headers set by hand, which
    /// URLSession would otherwise carry along.
    final class SameSiteRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            var next = request
            if task.originalRequest?.url?.host()?.lowercased() != request.url?.host()?.lowercased() {
                next.setValue(nil, forHTTPHeaderField: "Cookie")
                next.setValue(nil, forHTTPHeaderField: "Authorization")
            }
            return next
        }
    }

    /// The most of a feed or page read: past this it's not a feed anyone follows, and it would sit in memory.
    nonisolated static let feedByteLimit = 5 << 20

    /// Fetches `url` without cookies, stopping at `feedByteLimit`.
    nonisolated static func feedData(from url: URL) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await liveSession.bytes(from: url)
        if response.expectedContentLength > Int64(feedByteLimit) { throw LiveError(message: "That feed is too big to follow.") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > feedByteLimit { throw LiveError(message: "That feed is too big to follow.") }
        }
        return (data, response)
    }

    /// Searches github.com as the signed-in person. Each search tries the pulls dashboard, then
    /// the search page; results from all searches are merged.
    nonisolated static func fetchGitHubPulls(_ queries: [String], cookies: [String: String]) async throws -> Result<[FetchedItem], GitHubPulls.Failure> {
        guard cookies["Cookie"]?.contains("user_session=") == true else { return .failure(.notSignedIn) }
        let header = cookies
        var items: [FetchedItem] = []
        var failure: GitHubPulls.Failure?
        for query in queries {
            var answered = false
            for var request in GitHubPulls.requests(query: query) {
                for (k, v) in header { request.setValue(v, forHTTPHeaderField: k) }
                let (data, response) = try await liveSession.data(for: request)
                let http = response as? HTTPURLResponse
                switch GitHubPulls.read(data, status: http?.statusCode ?? 0, finalURL: http?.url) {
                case .success(let found):
                    items += found
                    answered = true
                case .failure(let f):
                    if f != .unexpectedPage { return .failure(f) }
                    failure = f
                }
                if answered { break }
            }
            if !answered, let failure { return .failure(failure) }
        }
        return .success(GitHubPulls.unique(items))
    }

    nonisolated static func fetchLive(_ kind: LiveSourceKind, cookies: [String: String] = [:],
                                      pullQueries: [String] = GitHubPulls.arcQueries) async -> Result<[FetchedItem], LiveError> {
        do {
            switch kind {
            case .githubPullRequests:
                switch try await fetchGitHubPulls(pullQueries, cookies: cookies) {
                case .success(let items): return .success(items)
                case .failure(let f): return .failure(LiveError(message: f.message))
                }
            case .feed(let url):
                guard let feed = try await fetchFeed(url) else {
                    return .failure(LiveError(message: "This address isn't a feed any more."))
                }
                return .success(feed.items)
            case .github(let query):
                // Signed in on github.com in this space: searched as you, like a tab. Anything else is a
                // public search. Browsa keeps no GitHub token of its own.
                if query.contains("is:pr"), case .success(let items)? = try? await fetchGitHubPulls([query], cookies: cookies) {
                    return .success(items)
                }
                if query.contains("@me") {
                    return .failure(LiveError(message: "Sign in to GitHub in this space to see your own pull requests."))
                }
                let (data, response) = try await liveSession.data(for: GitHubSearch.request(query: query))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    return .failure(LiveError(message: GitHubSearch.message(from: data) ?? "GitHub said \(status)."))
                }
                return .success(try GitHubSearch.items(from: data))
            }
        } catch let error as LiveError {
            return .failure(error)
        } catch {
            return .failure(LiveError(message: (error as? URLError)?.code == .notConnectedToInternet
                                      ? "You're offline." : error.localizedDescription))
        }
    }

    /// The feed at `url`. A web page leads to the first feed it lists.
    nonisolated static func fetchFeed(_ url: URL) async throws -> FeedParser.Feed? {
        let (data, response) = try await feedData(from: url)
        let base = response.url ?? url
        if let feed = FeedParser.parse(data, base: base) { return feed }
        let html = String(decoding: data.prefix(400_000), as: UTF8.self)
        for link in FeedDiscovery.feedLinks(inHTML: html, base: base).prefix(3) {
            let (data, response) = try await feedData(from: link)
            if let feed = FeedParser.parse(data, base: response.url ?? link) { return feed }
        }
        return nil
    }

    /// For "Follow a Site": the feed a page or address leads to, and its title.
    nonisolated static func resolveFeed(_ url: URL) async -> (url: URL, title: String)? {
        guard let page = try? await feedData(from: url) else { return nil }
        let base = page.1.url ?? url
        if let feed = FeedParser.parse(page.0, base: base) { return (url, feed.title) }
        let html = String(decoding: page.0.prefix(400_000), as: UTF8.self)
        for link in FeedDiscovery.feedLinks(inHTML: html, base: base).prefix(3) {
            if let found = try? await feedData(from: link),
               let feed = FeedParser.parse(found.0, base: found.1.url ?? link) {
                return (link, feed.title)
            }
        }
        return nil
    }
}
