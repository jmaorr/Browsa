#if os(iOS)
import Foundation
import Observation
import WebKit
import Suggest

/// The single source of truth shared by the folded and unfolded layouts. Folding the phone swaps
/// the layout view only, so tabs and their web views survive untouched.
@MainActor @Observable
public final class BrowserState {
    public var spaces: [Space]
    public var selectedSpaceID: UUID
    public var favorites: [Favorite]
    public var archive: [BrowserTab] = []

    // Transient UI state
    public var isNewTabSheetPresented = false
    /// When the sheet is opened from the address pill to edit the current URL rather than for a new tab.
    public var newTabSheetEditsCurrentTab = false
    public var isTabSwitcherPresented = false
    public var isSettingsPresented = false
    /// Which on-screen control opened the new-tab sheet, so it can zoom out of (and back into) it.
    public var newTabSourceID = "plus.bottomBar"
    /// Direction of the last swipe between tabs, for push transitions (nil = not a swipe).
    public var lastTabSwipeForward: Bool?
    public var isArchivePresented = false
    public var isDownloadsPresented = false
    /// The dialog, permission or login request on screen now (one at a time).
    public internal(set) var activePrompt: WebPrompt?
    /// Short confirmation shown at the top of the screen ("Opened in background").
    public var toast: String?
    /// Set by the app from the hinge. Drives desktop vs mobile sites.
    public var isUnfolded = false
    @ObservationIgnored var promptQueue: [(WebPrompt, CheckedContinuation<WebPromptResponse, Never>)] = []
    @ObservationIgnored var promptLog: [UUID: [Date]] = [:]
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Tabs closed this session, newest last, for Cmd-Shift-T. In memory only, never private tabs.
    public private(set) var recentlyClosed: [BrowserTab] = []
    /// Small pictures of each tab's page for the tab grid, taken as you leave a tab.
    /// In memory only; a tab without one shows its icon.
    public var thumbnails: [UUID: UIImage] = [:]
    /// Filter list download/compile state, for Settings.
    public internal(set) var filterStatus = FilterStatus()
    @ObservationIgnored var blockingTask: Task<Void, Never>?
    @ObservationIgnored var lastCookieToastURL: String?
    /// The article shown in Reader, when it's open.
    public var readerArticle: ReaderArticle?
    /// Live downloads and finished files, newest first.
    public let downloads = DownloadManager()

    public var settings = BrowserSettings() {
        didSet {
            guard settings != oldValue else { return }
            if settings.searchEngine != oldValue.searchEngine || settings.remoteSuggestions != oldValue.remoteSuggestions {
                suggest = makeSuggestEngine()
            }
            if settings.blockContent != oldValue.blockContent || settings.filterGroups != oldValue.filterGroups
                || settings.declineCookieBanners != oldValue.declineCookieBanners
                || settings.blockingDisabledHosts != oldValue.blockingDisabledHosts {
                applyContentBlocking()
            }
            scheduleSave()
        }
    }
    public var searchEngine: SearchEngine { settings.searchEngine }

    public let history: HistoryStore
    @ObservationIgnored let pool = WebViewPool()
    @ObservationIgnored public private(set) var suggest: SuggestEngine!
    @ObservationIgnored private let snapshotURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public init(history: HistoryStore = HistoryStore(fileURL: HistoryStore.defaultFileURL()),
                snapshotURL: URL? = BrowserState.defaultSnapshotURL()) {
        self.history = history
        self.snapshotURL = snapshotURL
        if let snapshotURL, let data = try? Data(contentsOf: snapshotURL),
           let snap = try? JSONDecoder().decode(BrowserSnapshot.self, from: data), !snap.spaces.isEmpty {
            spaces = snap.spaces.map(Space.init)
            selectedSpaceID = snap.selectedSpaceID ?? snap.spaces[0].id
            favorites = snap.favorites
            archive = snap.archive.map(BrowserTab.init)
            if let s = snap.settings { settings = s }
        } else {
            let personal = Space(name: "Personal", symbol: "house.fill", colorIndex: 0)
            spaces = [personal, Space(name: "Work", symbol: "briefcase.fill", colorIndex: 1)]
            selectedSpaceID = personal.id
            favorites = []
        }
        suggest = makeSuggestEngine()
        applyContentBlocking()
    }


    public static func defaultSnapshotURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "Browser/state.json")
    }

    // MARK: Selection

    public var currentSpace: Space {
        spaces.first { $0.id == selectedSpaceID } ?? spaces[0]
    }

    public var currentTab: BrowserTab? { currentSpace.selectedTab }

    public func session(for tab: BrowserTab) -> TabSession {
        pool.session(for: tab, browser: self)
    }

    public func select(_ tab: BrowserTab) {
        // Picture the page we're leaving while it's still on screen.
        if let leaving = currentTab, leaving.id != tab.id { captureThumbnail(of: leaving) }
        if let space = spaces.first(where: { $0.allTabs.contains { $0.id == tab.id } }) {
            selectedSpaceID = space.id
            space.selectedTabID = tab.id
        }
        tab.lastActive = .now
        scheduleSave()
    }

    public func selectSpace(_ space: Space) {
        selectedSpaceID = space.id
        scheduleSave()
    }

    // MARK: New tab / navigation

    /// One tap on any plus button.
    public func presentNewTab(from sourceID: String? = nil) {
        if let sourceID { newTabSourceID = sourceID }
        newTabSheetEditsCurrentTab = false
        isNewTabSheetPresented = true
    }

    /// Tap on the address pill / field.
    public func presentAddressEditor(from sourceID: String? = nil) {
        if let sourceID { newTabSourceID = sourceID }
        newTabSheetEditsCurrentTab = currentTab != nil
        isNewTabSheetPresented = true
    }

    @discardableResult
    public func newTab(url: URL?, in space: Space? = nil, isPrivate: Bool = false,
                       source: Frecency.VisitSource = .typed) -> BrowserTab {
        let space = space ?? currentSpace
        let tab = BrowserTab(url: nil, isPrivate: isPrivate)
        space.today.insert(tab, at: 0)
        select(tab)
        if let url { session(for: tab).load(url, source: source) }
        return tab
    }

    /// Handles a tapped suggestion, favourite or Return in the new-tab sheet.
    public func perform(_ action: SuggestionAction, source: Frecency.VisitSource = .typed) {
        let reuseCurrent = newTabSheetEditsCurrentTab
        isNewTabSheetPresented = false
        switch action {
        case .switchToTab(let id, _):
            if let tab = spaces.flatMap(\.allTabs).first(where: { $0.id == id }) { select(tab) }
        case .open(let url):
            navigate(to: url, reuseCurrent: reuseCurrent, source: source)
        case .search(let q):
            navigate(to: searchEngine.searchURL(for: q), reuseCurrent: reuseCurrent, source: source)
        case .command(let id):
            run(command: id)
        }
    }

    // MARK: Command bar

    /// Commands that make sense right now, for the command bar.
    public func availableCommands() -> [BrowserCommand] {
        var out: [BrowserCommand] = []
        if let tab = currentTab {
            out.append(BrowserCommand(id: "pin", title: tab.isPinned ? "Unpin Tab" : "Pin Tab", keywords: ["tab"]))
            if let url = tab.url, !isFavorite(url) {
                out.append(BrowserCommand(id: "favourite", title: "Add to Favourites", subtitle: tab.displayTitle,
                                          keywords: ["favorite", "star", "bookmark"]))
            }
            out.append(BrowserCommand(id: "close", title: "Close Tab", keywords: ["tab"]))
            if let url = tab.url {
                out.append(BrowserCommand(id: "copy-link", title: "Copy Link", subtitle: url.absoluteString, keywords: ["url", "share"]))
            }
        }
        if currentSpace.today.count > 1 {
            out.append(BrowserCommand(id: "close-others", title: "Close Other Tabs", keywords: ["tabs", "clean"]))
        }
        if let last = recentlyClosed.last {
            out.append(BrowserCommand(id: "reopen", title: "Reopen Closed Tab", subtitle: last.displayTitle, keywords: ["undo", "restore"]))
        }
        if let tab = currentTab, tab.url != nil {
            out.append(BrowserCommand(id: "desktop", title: tab.isDesktopSite ? "Request Mobile Site" : "Request Desktop Site",
                                      keywords: ["desktop", "mobile", "user agent"]))
            out.append(BrowserCommand(id: "find", title: "Find on Page", keywords: ["search", "text"]))
            out.append(BrowserCommand(id: "reload", title: "Reload Page", keywords: ["refresh"]))
        }
        if !downloads.items.isEmpty {
            out.append(BrowserCommand(id: "downloads", title: "Show Downloads", subtitle: "\(downloads.items.count) files", keywords: ["files"]))
        }
        out.append(BrowserCommand(id: "private", title: "New Private Tab", keywords: ["incognito"]))
        for s in spaces where s.id != selectedSpaceID {
            out.append(BrowserCommand(id: "space:" + s.id.uuidString, title: "Switch to \(s.name)", subtitle: "Space", keywords: ["space"]))
        }
        out.append(BrowserCommand(id: "settings", title: "Settings", keywords: ["preferences", "search engine"]))
        out.append(BrowserCommand(id: "archive", title: "Show Archive", subtitle: "\(archive.count) archived tabs", keywords: ["history", "closed"]))
        return out
    }

    public func run(command id: String) {
        isNewTabSheetPresented = false
        switch id {
        case "pin": if let t = currentTab { togglePinned(t) }
        case "favourite": if let t = currentTab, let url = t.url { addFavorite(url: url, title: t.displayTitle) }
        case "close": if let t = currentTab { close(t) }
        case "copy-link": if let url = currentTab?.url { copyToPasteboard(url) }
        case "close-others":
            let keep = currentTab?.id
            for t in currentSpace.today where t.id != keep { close(t) }
        case "private":
            newTab(url: nil, isPrivate: true)
            presentAddressEditor()
        case "reopen": reopenClosedTab()
        case "find":
            // Wait for the sheet to finish dismissing so the find bar can take first responder.
            Task { try? await Task.sleep(for: .milliseconds(350)); findInPage() }
        case "reload": reload()
        case "desktop": toggleDesktopSite()
        case "downloads": isDownloadsPresented = true
        case "settings": isSettingsPresented = true
        case "archive": isArchivePresented = true
        default:
            if id.hasPrefix("space:"), let uuid = UUID(uuidString: String(id.dropFirst(6))),
               let s = spaces.first(where: { $0.id == uuid }) {
                selectSpace(s)
            } else if id.hasPrefix("restore:"), let uuid = UUID(uuidString: String(id.dropFirst(8))),
                      let t = archive.first(where: { $0.id == uuid }) {
                restoreFromArchive(t)
            }
        }
    }

    private func navigate(to url: URL, reuseCurrent: Bool, source: Frecency.VisitSource) {
        if reuseCurrent, let tab = currentTab {
            session(for: tab).load(url, source: source)
        } else {
            newTab(url: url, source: source)
        }
    }

    func openPopup(url: URL, configuration: WKWebViewConfiguration, from opener: BrowserTab) -> WKWebView {
        let space = spaces.first { $0.allTabs.contains { $0.id == opener.id } } ?? currentSpace
        let tab = BrowserTab(url: url, isPrivate: opener.isPrivate)
        space.today.insert(tab, at: 0)
        let s = TabSession(tab: tab, configuration: configuration, browser: self, loadInitial: false)
        pool.adopt(s)
        select(tab)
        return s.webView
    }

    // MARK: Tab management

    public func close(_ tab: BrowserTab) {
        cancelPrompts(for: tab.id)
        if !tab.isPrivate, !tab.isPinned, tab.url != nil {
            pool.existingSession(for: tab.id)?.freeze()
            recentlyClosed.append(tab)
            if recentlyClosed.count > 25 { recentlyClosed.removeFirst() }
        }
        for space in spaces {
            if let i = space.today.firstIndex(where: { $0.id == tab.id }) {
                space.today.remove(at: i)
                if space.selectedTabID == tab.id {
                    let next: BrowserTab? = space.today.indices.contains(i) ? space.today[i] : (space.today.last ?? space.pinned.last)
                    space.selectedTabID = next?.id
                }
            } else if tab.isPinned, space.selectedTabID == tab.id {
                // Closing a pinned tab just unloads it, like Arc.
                space.selectedTabID = nil
            }
        }
        pool.remove(tab.id)
        thumbnails[tab.id] = nil
        scheduleSave()
    }

    /// Moves a tab within Today, for drag-to-reorder in the tab grid.
    public func moveTab(_ tab: BrowserTab, before target: BrowserTab) {
        let space = currentSpace
        guard tab.id != target.id, let from = space.today.firstIndex(where: { $0.id == tab.id }),
              let to = space.today.firstIndex(where: { $0.id == target.id }) else { return }
        space.today.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to)
        scheduleSave()
    }

    /// Snapshots a tab's page if its web view is on screen. Synchronous, so it can run just
    /// before the view is swapped out.
    public func captureThumbnail(of tab: BrowserTab) {
        guard tab.url != nil, let image = pool.existingSession(for: tab.id)?.renderThumbnail() else { return }
        thumbnails[tab.id] = image
    }

    /// Cmd-Shift-T: bring back the last closed tab, with its back/forward history.
    public func reopenClosedTab() {
        guard let tab = recentlyClosed.popLast() else { return }
        tab.lastActive = .now
        currentSpace.today.insert(tab, at: 0)
        select(tab)
    }

    /// Pinned then today, the order the sidebar and the tab strip show.
    public var orderedTabs: [BrowserTab] { currentSpace.pinned + currentSpace.today }

    /// Cmd-1...8 pick that tab; Cmd-9 always picks the last one (as in Safari).
    public func selectTab(number n: Int) {
        let tabs = orderedTabs
        guard !tabs.isEmpty else { return }
        let i = n >= 9 ? tabs.count - 1 : n - 1
        guard tabs.indices.contains(i) else { return }
        select(tabs[i])
    }

    /// Ctrl-Tab / Ctrl-Shift-Tab. Wraps around.
    public func selectAdjacentTab(_ delta: Int) {
        let tabs = orderedTabs
        guard tabs.count > 1, let cur = currentTab, let i = tabs.firstIndex(where: { $0.id == cur.id }) else { return }
        lastTabSwipeForward = delta > 0
        select(tabs[(i + delta + tabs.count) % tabs.count])
    }

    // MARK: Links

    /// Long-press > Open in Background: a new today tab right after the opener, loading quietly.
    public func openInBackground(_ url: URL, from opener: BrowserTab?) {
        let space = opener.flatMap { o in spaces.first { $0.allTabs.contains { $0.id == o.id } } } ?? currentSpace
        let tab = BrowserTab(url: url, isPrivate: opener?.isPrivate ?? false)
        let after = opener.flatMap { o in space.today.firstIndex { $0.id == o.id } }.map { $0 + 1 } ?? 0
        space.today.insert(tab, at: after)
        session(for: tab).load(url, source: .link)
        // Loading made it most-recently-used in the pool; the visible tab must stay ahead of it.
        if let current = currentTab { _ = session(for: current) }
        showToast("Opened in background")
        scheduleSave()
    }

    public func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Desktop / mobile sites

    /// Desktop on the inner display, mobile on the outer, unless the site has an override.
    func prefersDesktop(for url: URL?) -> Bool {
        if let host = url.map(URLNormalizer.displayHost), let o = settings.siteDesktopOverrides[host] { return o }
        return isUnfolded && settings.desktopSitesWhenUnfolded
    }

    /// "Request Desktop Site" / "Request Mobile Site": remembered for the site, page reloads.
    public func toggleDesktopSite() {
        guard let tab = currentTab, let url = tab.url else { return }
        let host = URLNormalizer.displayHost(url)
        let wantDesktop = !tab.isDesktopSite
        // Store an override only when it differs from what the posture would pick anyway.
        let natural = isUnfolded && settings.desktopSitesWhenUnfolded
        settings.siteDesktopOverrides[host] = wantDesktop == natural ? nil : wantDesktop
        // reloadFromOrigin re-runs the navigation policy, so the new content mode applies.
        session(for: tab).webView.reloadFromOrigin()
    }

    // MARK: Current page actions

    public func goBack() { currentTab.map { session(for: $0).webView.goBack() } }
    public func goForward() { currentTab.map { session(for: $0).webView.goForward() } }
    public func reload() { currentTab.map { session(for: $0).webView.reload() } }
    public func stopLoading() { currentTab.map { session(for: $0).webView.stopLoading() } }

    /// Cmd-F: the system find bar (same one Safari uses), which sits above the keyboard.
    public func findInPage() {
        guard let tab = currentTab, tab.url != nil else { return }
        session(for: tab).webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    /// Cmd-D: toggles the current page in favourites.
    public func toggleFavoriteForCurrentTab() {
        guard let tab = currentTab, let url = tab.url else { return }
        let key = URLNormalizer.key(for: url)
        if let f = favorites.first(where: { URLNormalizer.key(for: $0.url) == key }) { removeFavorite(f) }
        else { addFavorite(url: url, title: tab.displayTitle) }
    }

    public func togglePinned(_ tab: BrowserTab) {
        let space = spaces.first { $0.allTabs.contains { $0.id == tab.id } } ?? currentSpace
        if tab.isPinned {
            space.pinned.removeAll { $0.id == tab.id }
            space.today.insert(tab, at: 0)
        } else {
            space.today.removeAll { $0.id == tab.id }
            space.pinned.append(tab)
        }
        tab.isPinned.toggle()
        scheduleSave()
    }

    /// Call on launch and when returning to the foreground.
    public func archiveStaleTabs(now: Date = .now) {
        for space in spaces {
            let stale = space.today.filter { $0.id != space.selectedTabID && now.timeIntervalSince($0.lastActive) > settings.archiveAfterHours * 3600 }
            guard !stale.isEmpty else { continue }
            space.today.removeAll { t in stale.contains { $0.id == t.id } }
            stale.forEach { pool.existingSession(for: $0.id)?.freeze(); pool.remove($0.id) }
            archive.insert(contentsOf: stale.filter { !$0.isPrivate }, at: 0)
        }
        archive = Array(archive.prefix(500))
        scheduleSave()
    }

    // MARK: Spaces

    public func addSpace() {
        let used = Set(spaces.map(\.colorIndex))
        let color = (0..<6).first { !used.contains($0) } ?? spaces.count
        let space = Space(name: "Space \(spaces.count + 1)", symbol: "circle.fill", colorIndex: color)
        spaces.append(space)
        scheduleSave()
    }

    public func deleteSpace(_ space: Space) {
        guard spaces.count > 1, let i = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        space.allTabs.forEach { pool.remove($0.id) }
        spaces.remove(at: i)
        if selectedSpaceID == space.id { selectedSpaceID = spaces[0].id }
        if settings.externalLinksSpaceID == space.id { settings.externalLinksSpaceID = nil }
        scheduleSave()
    }

    /// A link opened from another app (once this is the default browser).
    public func openExternal(_ url: URL) {
        let target = spaces.first { $0.id == settings.externalLinksSpaceID } ?? currentSpace
        isNewTabSheetPresented = false
        newTab(url: url, in: target, source: .link)
    }

    // MARK: Archive

    public func restoreFromArchive(_ tab: BrowserTab) {
        archive.removeAll { $0.id == tab.id }
        tab.lastActive = .now
        currentSpace.today.insert(tab, at: 0)
        select(tab)
    }

    public func clearArchive() {
        archive.removeAll()
        scheduleSave()
    }

    // MARK: Favourites

    public func isFavorite(_ url: URL) -> Bool {
        let key = URLNormalizer.key(for: url)
        return favorites.contains { URLNormalizer.key(for: $0.url) == key }
    }

    public func addFavorite(url: URL, title: String) {
        guard !isFavorite(url) else { return }
        favorites.append(Favorite(url: url, title: title, order: (favorites.map(\.order).max() ?? -1) + 1))
        Task { await history.setBookmarked(url, true) }
        scheduleSave()
    }

    public func removeFavorite(_ fav: Favorite) {
        favorites.removeAll { $0.id == fav.id }
        Task { await history.setBookmarked(fav.url, false) }
        scheduleSave()
    }

    public func renameFavorite(_ fav: Favorite, to name: String) {
        guard let i = favorites.firstIndex(where: { $0.id == fav.id }) else { return }
        favorites[i].customName = name.isEmpty ? nil : name
        scheduleSave()
    }

    public func moveFavorites(fromOffsets: IndexSet, toOffset: Int) {
        var sorted = favorites.sorted { $0.order < $1.order }
        sorted.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for i in sorted.indices { sorted[i].order = i }
        favorites = sorted
        scheduleSave()
    }

    // MARK: Suggest wiring

    private func makeSuggestEngine() -> SuggestEngine {
        // The engine runs off the main actor; give it snapshots, never live model objects.
        SuggestEngine(
            history: history,
            favorites: { [weak self] in
                await MainActor.run { self?.favorites ?? [] }
            },
            openTabs: { [weak self] in
                await MainActor.run {
                    guard let self else { return [] }
                    return self.spaces.flatMap(\.allTabs)
                        .filter { $0.url != nil && $0.id != self.currentTab?.id }
                        .sorted { $0.lastActive > $1.lastActive }
                        .map { OpenTabSnapshot(id: $0.id, url: $0.url!, title: $0.title) }
                }
            },
            searchEngine: settings.searchEngine,
            remoteSuggestionsEnabled: settings.remoteSuggestions,
            extraProviders: [
                CommandProvider(commands: { [weak self] in
                    await MainActor.run { self?.availableCommands() ?? [] }
                }),
                ArchivedTabsProvider(tabs: { [weak self] in
                    await MainActor.run {
                        (self?.archive ?? []).compactMap { t in
                            t.url.map { OpenTabSnapshot(id: t.id, url: $0, title: t.title) }
                        }
                    }
                }),
            ])
    }

    // MARK: Persistence

    public func scheduleSave() {
        guard snapshotURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    public func saveNow() {
        guard let snapshotURL else { return }
        pool.freezeAll()
        let snap = BrowserSnapshot(spaces: spaces.map(\.record), selectedSpaceID: selectedSpaceID,
                                   favorites: favorites, archive: archive.map(\.record), settings: settings)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: snapshotURL, options: .atomic)
        Task { await history.saveNow() }
    }
}
#endif
