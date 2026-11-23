import Foundation
import AppKit
import Security
import SwiftUI
import BrowserCore

/// Live Folders: pinned folders that fill themselves from a feed or a GitHub search (see
/// `LiveFolders` for the rules). Each item is an ordinary pinned tab inside the folder, so opening,
/// moving and unloading work as they do for any pinned tab. Folders check every 15 minutes, when
/// Browsa starts, and when you open one that hasn't checked for a while.
extension Library {
    /// How often the loop wakes. GitHub folders check this often while Browsa is in front (Dia's
    /// 2 minutes); feeds every 15 minutes.
    static let liveTick: Duration = .seconds(120)
    static let feedInterval: TimeInterval = 15 * 60

    /// Starts the checks. Called once, from `init`.
    func startLiveFolders() {
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
        let folder = PinnedFolder(name: name, isOpen: true, live: LiveSource(kind: kind))
        setPinnedLayout(PinnedOutline.inserting(.folder(folder), at: PinnedPlace(parent: nil, index: 0), in: space.pinnedTree), in: space)
        Task { await refreshLiveFolder(folder.id, in: space) }
        return folder.id
    }

    /// Points a live folder somewhere else. What it held goes, and the new source fills it.
    func changeLiveFolder(_ id: UUID, to kind: LiveSourceKind, name: String, in space: Space) {
        guard let folder = PinnedOutline.folder(id, in: space.pinnedTree), let live = folder.live else { return }
        if live.kind != kind { removeLiveTabs(live.items.map(\.tabID), in: space) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        setPinnedLayout(PinnedOutline.updating(id, in: space.pinnedTree) { f in
            if !name.isEmpty { f.name = name }
            if live.kind != kind { f.live = LiveSource(kind: kind) }
        }, in: space)
        if live.kind != kind { Task { await refreshLiveFolder(id, in: space) } }
    }

    /// The folder stops updating and keeps what it holds as ordinary pinned tabs.
    func stopLiveFolder(_ id: UUID, in space: Space) {
        setPinnedLayout(PinnedOutline.updating(id, in: space.pinnedTree) { $0.live = nil }, in: space)
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
        guard !liveRefreshing.contains(id), let kind = PinnedOutline.folder(id, in: space.pinnedTree)?.live?.kind else { return }
        liveRefreshing.insert(id)
        defer { liveRefreshing.remove(id) }
        // GitHub is read as you: the space's own github.com login goes along, as in a tab.
        var cookies: [String: String] = [:]
        if kind.usesGitHubLogin {
            let jar = await engine.cookies(for: profile(for: space), url: URL(string: "https://github.com/pulls")!)
            cookies = HTTPCookie.requestHeaderFields(with: jar)
        }
        let result = await Self.fetchLive(kind, cookies: cookies)
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

    /// Adds the space's GitHub folder (Arc's "Pull Requests"), or takes it away with its items.
    func toggleGitHubFolder(in space: Space) {
        if let folder = gitHubFolder(in: space) {
            removeLiveFolder(folder.id, in: space)
        } else {
            newLiveFolder(.githubPullRequests, name: "Pull Requests", in: space)
        }
    }

    /// A page finished loading. On github.com: offer the GitHub folder once, and check the space's
    /// GitHub folders soon after you open or review a pull request (as Dia does), so it shows up
    /// without waiting for the next check.
    func liveFolderPageFinished(_ url: URL, in tab: BrowserTab) {
        guard !tab.isPrivate, url.host()?.lowercased() == "github.com", let space = space(containing: tab), !space.isPrivate else { return }
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

    /// Spaces that have had their GitHub folder made for them, so deleting it keeps it gone (it
    /// comes back from Live Folders › GitHub Pull Requests).
    private static let gitHubAutoKey = "liveFolders.gitHubFolderMadeForSpaces"

    /// As Arc felt: the first time a space is signed in on github.com and you have open pull requests
    /// or review requests, its "Pull Requests" folder appears, with an Undo.
    private func makeGitHubFolderIfWanted(in space: Space, from tab: BrowserTab) {
        let done = UserDefaults.standard.stringArray(forKey: Self.gitHubAutoKey) ?? []
        guard !done.contains(space.id.uuidString), gitHubFolder(in: space) == nil, !gitHubAutoChecking else { return }
        // No open pull requests last time: look again in a while, not on every page.
        if let last = gitHubAutoLastCheck[space.id], Date.now.timeIntervalSince(last) < 10 * 60 { return }
        gitHubAutoLastCheck[space.id] = .now
        gitHubAutoChecking = true
        Task {
            defer { gitHubAutoChecking = false }
            let jar = await engine.cookies(for: profile(for: space), url: URL(string: "https://github.com/pulls")!)
            let header = HTTPCookie.requestHeaderFields(with: jar)
            guard case .success(let items)? = try? await Self.fetchGitHubPulls(GitHubPulls.arcQueries, cookies: header),
                  !items.isEmpty, gitHubFolder(in: space) == nil else { return }
            UserDefaults.standard.set(done + [space.id.uuidString], forKey: Self.gitHubAutoKey)
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

    /// A session that keeps no cookies of its own: the space's are handed in per request.
    nonisolated static let liveSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

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

    nonisolated static func fetchLive(_ kind: LiveSourceKind, cookies: [String: String] = [:]) async -> Result<[FetchedItem], LiveError> {
        do {
            switch kind {
            case .githubPullRequests:
                switch try await fetchGitHubPulls(GitHubPulls.arcQueries, cookies: cookies) {
                case .success(let items): return .success(items)
                case .failure(let f): return .failure(LiveError(message: f.message))
                }
            case .feed(let url):
                guard let feed = try await fetchFeed(url) else {
                    return .failure(LiveError(message: "This address isn't a feed any more."))
                }
                return .success(feed.items)
            case .github(let query):
                // Signed in on github.com in this space: no token needed. Otherwise the token, if any.
                if query.contains("is:pr"), case .success(let items)? = try? await fetchGitHubPulls([query], cookies: cookies) {
                    return .success(items)
                }
                let token = await GitHubToken.value
                let (data, response) = try await URLSession.shared.data(for: GitHubSearch.request(query: query, token: token))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    if status == 401 { return .failure(LiveError(message: "GitHub didn't accept the token. Add a new one.")) }
                    if status == 422, token == nil, query.contains("@me") {
                        return .failure(LiveError(message: "Sign in to GitHub in this space (or add a token) to see your own pull requests."))
                    }
                    return .failure(LiveError(message: GitHubSearch.message(from: data) ?? "GitHub said \(status)."))
                }
                return .success(try GitHubSearch.items(from: data))
            }
        } catch {
            return .failure(LiveError(message: (error as? URLError)?.code == .notConnectedToInternet
                                      ? "You're offline." : error.localizedDescription))
        }
    }

    /// The feed at `url`. A web page leads to the first feed it lists.
    nonisolated static func fetchFeed(_ url: URL) async throws -> FeedParser.Feed? {
        let (data, response) = try await URLSession.shared.data(from: url)
        let base = response.url ?? url
        if let feed = FeedParser.parse(data, base: base) { return feed }
        let html = String(decoding: data.prefix(400_000), as: UTF8.self)
        for link in FeedDiscovery.feedLinks(inHTML: html, base: base).prefix(3) {
            let (data, response) = try await URLSession.shared.data(from: link)
            if let feed = FeedParser.parse(data, base: response.url ?? link) { return feed }
        }
        return nil
    }

    /// For the new folder sheet: the feed a page or address leads to, and its title.
    nonisolated static func resolveFeed(_ url: URL) async -> (url: URL, title: String)? {
        guard let page = try? await URLSession.shared.data(from: url) else { return nil }
        let base = page.1.url ?? url
        if let feed = FeedParser.parse(page.0, base: base) { return (url, feed.title) }
        let html = String(decoding: page.0.prefix(400_000), as: UTF8.self)
        for link in FeedDiscovery.feedLinks(inHTML: html, base: base).prefix(3) {
            if let found = try? await URLSession.shared.data(from: link),
               let feed = FeedParser.parse(found.0, base: found.1.url ?? link) {
                return (link, feed.title)
            }
        }
        return nil
    }
}

/// The GitHub token live folders search with, kept in the Keychain. Optional: public searches
/// work without one, but `@me` needs it.
enum GitHubToken {
    private static let service = "com.orriginal.browsa.github-token"

    @MainActor static var value: String? {
        var query: [String: Any] = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self)
        return token.isEmpty ? nil : token
    }

    @MainActor static func set(_ token: String?) {
        SecItemDelete(base as CFDictionary)
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "live-folders"]
    }

    /// Where to make one: a classic token with read access to private repos.
    static let newTokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=Browsa%20Live%20Folders")!
}
