import Foundation
import Security
import BrowserCore

/// Live Folders: pinned folders that fill themselves from a feed or a GitHub search (see
/// `LiveFolders` for the rules). Each item is an ordinary pinned tab inside the folder, so opening,
/// moving and unloading work as they do for any pinned tab. Folders check every 15 minutes, when
/// Browsa starts, and when you open one that hasn't checked for a while.
extension Library {
    static let liveCheckInterval: Duration = .seconds(15 * 60)

    /// Starts the checks. Called once, from `init`.
    func startLiveFolders() {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            while !Task.isCancelled {
                await self?.refreshAllLiveFolders()
                try? await Task.sleep(for: Library.liveCheckInterval)
            }
        }
        updateLiveUnread()
    }

    func refreshAllLiveFolders() async {
        for space in regularSpaces {
            for folder in LiveFolders.liveFolders(in: space.pinnedTree) {
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
        let result = await Self.fetchLive(kind)
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

    nonisolated static func fetchLive(_ kind: LiveSourceKind) async -> Result<[FetchedItem], LiveError> {
        do {
            switch kind {
            case .feed(let url):
                guard let feed = try await fetchFeed(url) else {
                    return .failure(LiveError(message: "This address isn't a feed any more."))
                }
                return .success(feed.items)
            case .github(let query):
                let token = await GitHubToken.value
                let (data, response) = try await URLSession.shared.data(for: GitHubSearch.request(query: query, token: token))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    if status == 401 { return .failure(LiveError(message: "GitHub didn't accept the token. Add a new one.")) }
                    if status == 422, token == nil, query.contains("@me") {
                        return .failure(LiveError(message: "Add a GitHub token to search for your own pull requests."))
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
