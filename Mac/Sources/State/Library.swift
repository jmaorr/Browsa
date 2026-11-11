import AppKit
import Observation
import BrowserCore
import BrowserEngine
import Suggest
import Extensibility

/// Everything the windows share: spaces, tabs, favourites, settings, live pages and downloads.
/// Each window is a `Browser` looking into it with its own space and tab.
///
/// Engine-neutral: pages come from `engine`, and nothing here knows it's WebKit.
@MainActor @Observable
final class Library {
    var spaces: [Space]
    /// Shared across spaces, like Arc's favourites row.
    var favorites: [Favorite]
    var archive: [BrowserTab] = []
    var settings = BrowserSettings() {
        didSet {
            guard settings != oldValue else { return }
            if settings.searchEngine != oldValue.searchEngine || settings.remoteSuggestions != oldValue.remoteSuggestions {
                suggest = makeSuggestEngine()
            }
            if settings.blockContent != oldValue.blockContent || settings.filterGroups != oldValue.filterGroups
                || settings.declineCookieBanners != oldValue.declineCookieBanners
                || settings.blockingDisabledHosts != oldValue.blockingDisabledHosts {
                applyBlocking()
            }
            scheduleSave()
        }
    }
    /// Sends the Global Privacy Control signal (`navigator.globalPrivacyControl`) to every site.
    var globalPrivacyControl: Bool { didSet { Preferences.globalPrivacyControl = globalPrivacyControl; applyBlocking() } }
    /// Forget history, cookies and site data when Browsa quits.
    var clearDataOnQuit: Bool { didSet { Preferences.clearDataOnQuit = clearDataOnQuit } }
    /// Inspect Element on every page.
    var developerTools: Bool {
        didSet { Preferences.developerTools = developerTools; engine.developerToolsEnabled = developerTools }
    }
    /// Safari web extensions installed on this Mac, run in every page.
    var useSafariExtensions: Bool {
        didSet { Preferences.useSafariExtensions = useSafariExtensions; reloadExtensions() }
    }
    /// The extensions running now, for the toolbar.
    private(set) var extensions: [EngineExtension] = []
    /// Bumped when pins change or an extension updates its action, so the address pill redraws.
    var extensionPinsRevision = 0
    var extensionActionsRevision = 0
    /// Extensions added from the Chrome Web Store, Firefox Add-ons or a folder (Safari ones come from apps).
    let extensionCatalog: ExtensionCatalog
    @ObservationIgnored let extensionInstaller: ExtensionInstaller
    /// Notes pinned to pages, which agents read too.
    let margin: MarginStore
    /// Every tool that plugs into the window: the right panel, sidebar sections, command bar rows.
    let workbench = Workbench()
    /// Coding agents over MCP. Made after everything else, since it reaches back into the library.
    @ObservationIgnored private(set) var agents: AgentBridge!
    var downloads: [EngineDownload] = []
    var filterStatus = FilterStatus()
    /// Tabs closed this session, newest last, for Shift-Cmd-T. Never private tabs.
    private(set) var recentlyClosed: [BrowserTab] = []
    /// The open windows, most recently active first.
    private(set) var windows: [Browser] = []

    let engine: any BrowserEngine
    let history: HistoryStore
    @ObservationIgnored private(set) var suggest: SuggestEngine!
    /// Live pages, by tab. The least recently used are unloaded past `capacity`.
    @ObservationIgnored private(set) var controllers: [UUID: TabController] = [:]
    @ObservationIgnored private var lru: [UUID] = []
    @ObservationIgnored private let capacity = 24
    @ObservationIgnored private let snapshotURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var blockingTask: Task<Void, Never>?
    /// Kept so state written by the iPhone format round-trips; the Mac doesn't show Saved yet.
    @ObservationIgnored private var savedSites: [SavedSite] = []
    /// The space the first window opens on.
    @ObservationIgnored private(set) var launchSpaceID: UUID

    init(engine: any BrowserEngine,
         history: HistoryStore = HistoryStore(fileURL: HistoryStore.defaultFileURL()),
         snapshotURL: URL? = Library.defaultSnapshotURL()) {
        self.engine = engine
        self.history = history
        self.snapshotURL = snapshotURL
        globalPrivacyControl = Preferences.globalPrivacyControl
        clearDataOnQuit = Preferences.clearDataOnQuit
        developerTools = Preferences.developerTools
        useSafariExtensions = Preferences.useSafariExtensions
        let support = snapshotURL?.deletingLastPathComponent()
        extensionCatalog = ExtensionCatalog(fileURL: support?.appending(path: "extensions.json"))
        extensionInstaller = ExtensionInstaller(
            root: (support ?? FileManager.default.temporaryDirectory).appending(path: "Extensions"),
            fetch: Library.fetch, unzip: Library.unzip)
        margin = MarginStore(fileURL: support?.appending(path: "margin.json"))
        if let snapshotURL, let data = try? Data(contentsOf: snapshotURL),
           let snap = try? JSONDecoder().decode(BrowserSnapshot.self, from: data), !snap.spaces.isEmpty {
            spaces = snap.spaces.map(Space.init)
            launchSpaceID = snap.selectedSpaceID ?? snap.spaces[0].id
            favorites = snap.favorites
            archive = snap.archive.map(BrowserTab.init)
            savedSites = snap.saved ?? []
            if let s = snap.settings { settings = s }
        } else {
            let personal = Space(name: "Personal", symbol: "house.fill", colorIndex: 0)
            spaces = [personal, Space(name: "Work", symbol: "briefcase.fill", colorIndex: 1)]
            launchSpaceID = personal.id
            favorites = Self.starterFavorites
        }
        suggest = makeSuggestEngine()
        engine.developerToolsEnabled = developerTools
        applyBlocking()
        BoostStore.shared.attach(engine: engine)
        archiveStaleTabs()
        engine.extensionHost = self
        reloadExtensions()
        agents = AgentBridge(library: self)
        BuiltInTools.register(in: workbench)
        SpaceRouter.register(in: workbench, library: self)
        PluginHost.shared.library = self
        if developerTools { PluginHost.registerConsole(in: workbench) }
        NotesUI.installPageMenu(library: self)
        #if !SPIKE
        // SpikeBrowsa sets mock servers instead. Radar only looks at this Mac's ports while it's on
        // (it's in the Agent Pack, off for new installs).
        if workbench.isEnabled("radar") { startRadar() }
        workbench.onEnabledChange = { [weak self] id, on in
            guard id == "radar" else { return }
            if on { self?.startRadar() } else { RadarStore.shared.stopLive() }
        }
        #endif
    }

    #if !SPIKE
    private func startRadar() {
        RadarStore.shared.startLive(library: self, ownPorts: [Int(AgentBridge.port)])
    }
    #endif

    func reloadExtensions() {
        engine.unloadExtensions()
        extensions = []
        BuiltInTools.sync(extensions: [], in: workbench)
        guard engine.info.capabilities.contains(.webExtensions) else { return }
        let folders = extensionFolders()
        guard useSafariExtensions || !folders.isEmpty else { return }
        Task {
            // Extensions expect a browser window to exist when they start (chrome.windows.getCurrent).
            while windows.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            // What couldn't load is in the engine's log.
            _ = await engine.loadInstalledExtensions(folders: folders, includeApps: useSafariExtensions)
            extensions = engine.extensions
            BuiltInTools.sync(extensions: extensions, in: workbench)
        }
    }

    private static let starterFavorites: [Favorite] = [
        ("https://www.youtube.com", "YouTube"), ("https://github.com", "GitHub"),
        ("https://en.wikipedia.org", "Wikipedia"), ("https://www.apple.com", "Apple"),
    ].enumerated().map { i, f in Favorite(url: URL(string: f.0)!, title: f.1, order: i) }

    static func defaultSnapshotURL() -> URL {
        AppFolders.support.appending(path: "Browser/state.json")
    }

    // MARK: Windows

    func register(_ window: Browser) {
        windows.removeAll { $0 === window }
        windows.insert(window, at: 0)
    }

    func unregister(_ window: Browser) {
        windows.removeAll { $0 === window }
        // Its tabs stay in their spaces; only the window's view of them goes.
        scheduleSave()
    }

    /// The window someone's using, for things that arrive from outside (links, downloads).
    var activeWindow: Browser? {
        windows.first { $0.nsWindow?.isKeyWindow == true } ?? windows.first
    }

    func markActive(_ window: Browser) {
        guard windows.first !== window else { return }
        register(window)
    }

    /// The window showing a tab right now, if any. A tab is on screen in one window at most.
    func window(showing tab: BrowserTab) -> Browser? {
        windows.first { $0.currentTab?.id == tab.id }
    }

    /// Opens a window through SwiftUI. Set by the first window that appears.
    @ObservationIgnored var openWindowAction: (() -> Void)?
    @ObservationIgnored private var windowRequests: [WindowRequest] = []

    /// Opens a new window, showing `request` (or a new-tab command bar).
    func openWindow(_ request: WindowRequest? = nil) {
        if let request { windowRequests.append(request) }
        openWindowAction?()
    }

    /// What the window being made should show first.
    func takeWindowRequest() -> WindowRequest? {
        windowRequests.isEmpty ? nil : windowRequests.removeFirst()
    }

    /// A link from another app, in the window in use, or a new one when none is open.
    func openExternal(_ url: URL) {
        if let window = activeWindow {
            window.openExternal(url)
            NSApp.activate()
            window.nsWindow?.makeKeyAndOrderFront(nil)
        } else {
            openWindow(.url(url))
        }
    }

    func window(for nsWindow: NSWindow?) -> Browser? {
        guard let nsWindow else { return nil }
        return windows.first { $0.nsWindow === nsWindow }
    }

    // MARK: Lookup

    var regularSpaces: [Space] { spaces.filter { !$0.isPrivate } }
    var privateSpace: Space? { spaces.first { $0.isPrivate } }
    var allTabs: [BrowserTab] { spaces.flatMap(\.allTabs) }

    func space(containing tab: BrowserTab) -> Space? {
        spaces.first { $0.allTabs.contains { $0.id == tab.id } }
    }

    func tab(id: UUID) -> BrowserTab? { allTabs.first { $0.id == id } }

    // MARK: Pages

    /// The live page for a tab, made (and restored) on first use.
    func controller(for tab: BrowserTab) -> TabController {
        touch(tab.id)
        if let c = controllers[tab.id] { return c }
        let c = TabController(tab: tab, library: self) { delegate in
            engine.makePage(options: PageOptions(profile: tab.isPrivate ? .ephemeral : .standard,
                                                 // The welcome tab is native; its page starts blank.
                                                 url: Welcome.isWelcome(tab.url) || LibraryPage.isLibrary(tab.url) ? nil : tab.url,
                                                 sessionState: tab.interactionState),
                            delegate: delegate)
        }
        controllers[tab.id] = c
        evictIfNeeded(keeping: tab.id)
        return c
    }

    func existingController(for tab: BrowserTab) -> TabController? { controllers[tab.id] }

    private func adopt(_ controller: TabController) {
        controllers[controller.tab.id] = controller
        touch(controller.tab.id)
        evictIfNeeded(keeping: controller.tab.id)
    }

    private func touch(_ id: UUID) {
        lru.removeAll { $0 == id }
        lru.append(id)
    }

    private func evictIfNeeded(keeping id: UUID) {
        let onScreen = Set(windows.compactMap { $0.currentTab?.id })
        while lru.count > capacity, let victim = lru.first(where: { $0 != id && !onScreen.contains($0) }) {
            unload(victim)
        }
    }

    /// Saves a page's back/forward list onto its tab and lets the page go.
    private func unload(_ id: UUID) {
        if let c = controllers[id] {
            c.freeze()
            c.page.close()
        }
        controllers[id] = nil
        lru.removeAll { $0 == id }
    }

    // MARK: Opening tabs

    /// A new today tab at the top of a space. Opening into Private makes the Private space.
    @discardableResult
    func insertTab(url: URL?, in space: Space, isPrivate: Bool = false, source: Frecency.VisitSource = .typed,
                   at index: Int = 0) -> BrowserTab {
        let wantsPrivate = isPrivate || space.isPrivate
        let target = wantsPrivate ? openPrivateSpace() : space
        let tab = BrowserTab(url: nil, isPrivate: wantsPrivate)
        target.today.insert(tab, at: min(index, target.today.count))
        if let url { controller(for: tab).load(url, source: source) }
        scheduleSave()
        return tab
    }

    /// Cmd-click on a link: a new today tab just under the one it came from.
    func openInNewTab(_ url: URL, from opener: BrowserTab, foreground: Bool) {
        let space = space(containing: opener) ?? regularSpaces[0]
        let after = space.today.firstIndex { $0.id == opener.id }.map { $0 + 1 } ?? 0
        let tab = insertTab(url: url, in: space, isPrivate: opener.isPrivate, source: .link, at: after)
        let window = window(showing: opener)
        if foreground { window?.select(tab) } else { window?.showToast("Opened in background") }
    }

    /// A page opened a window. It becomes a tab right after its opener, in front.
    func openPopup(from opener: BrowserTab, page: any EnginePage, url: URL?) -> TabController {
        let space = space(containing: opener) ?? regularSpaces[0]
        let tab = BrowserTab(url: url, isPrivate: opener.isPrivate)
        let after = space.today.firstIndex { $0.id == opener.id }.map { $0 + 1 } ?? 0
        space.today.insert(tab, at: after)
        let c = TabController(tab: tab, library: self) { _ in page }
        adopt(c)
        (window(showing: opener) ?? activeWindow)?.select(tab)
        scheduleSave()
        return c
    }

    // MARK: Closing

    func close(_ tab: BrowserTab) {
        for w in windows { w.cancelPrompts(for: tab.id) }
        if !tab.isPrivate, !tab.isPinned, tab.url != nil {
            controllers[tab.id]?.freeze()
            recentlyClosed.append(tab)
            if recentlyClosed.count > 30 { recentlyClosed.removeFirst() }
        }
        guard let space = space(containing: tab) else { return }
        let index = space.today.firstIndex { $0.id == tab.id }
        // Windows showing it move on first, while it's still in the list to measure from.
        for w in windows where w.currentTab?.id == tab.id { w.moveOff(tab, in: space) }
        space.today.removeAll { $0.id == tab.id }
        if space.selectedTabID == tab.id { space.selectedTabID = nil }
        if index == nil, tab.isPinned {
            // Closing a pinned tab only unloads it, like Arc.
        }
        unload(tab.id)
        if let p = privateSpace, p.allTabs.isEmpty { closePrivateSpace() }
        scheduleSave()
    }

    func popRecentlyClosed() -> BrowserTab? { recentlyClosed.popLast() }

    // MARK: Organising

    func togglePinned(_ tab: BrowserTab) {
        guard !tab.isPrivate, let space = space(containing: tab) else { return }
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

    /// Drag and drop in the sidebar: `tab` lands just before `target`, or at the end of the section in `fallback`.
    func move(_ tab: BrowserTab, before target: BrowserTab?, pinned: Bool, fallback: Space) {
        guard let from = space(containing: tab), !(tab.isPrivate && pinned) else { return }
        let to = target.flatMap(space(containing:)) ?? fallback
        guard from.isPrivate == to.isPrivate else { return }
        from.pinned.removeAll { $0.id == tab.id }
        from.today.removeAll { $0.id == tab.id }
        tab.isPinned = pinned
        if pinned {
            let i = target.flatMap { t in to.pinned.firstIndex { $0.id == t.id } } ?? to.pinned.endIndex
            to.pinned.insert(tab, at: i)
        } else {
            let i = target.flatMap { t in to.today.firstIndex { $0.id == t.id } } ?? to.today.endIndex
            to.today.insert(tab, at: i)
        }
        if from.id != to.id { for w in windows { w.tabLeft(tab, space: from) } }
        scheduleSave()
    }

    func move(_ tab: BrowserTab, to space: Space) {
        guard let from = self.space(containing: tab), from.id != space.id, !space.isPrivate, !tab.isPrivate else { return }
        for w in windows where w.currentTab?.id == tab.id { w.moveOff(tab, in: from) }
        from.pinned.removeAll { $0.id == tab.id }
        from.today.removeAll { $0.id == tab.id }
        if from.selectedTabID == tab.id { from.selectedTabID = nil }
        tab.isPinned = false
        space.today.insert(tab, at: 0)
        scheduleSave()
    }

    // MARK: Favourites

    func isFavorite(_ url: URL) -> Bool {
        let key = URLNormalizer.key(for: url)
        return favorites.contains { URLNormalizer.key(for: $0.url) == key }
    }

    func addFavorite(url: URL, title: String) {
        guard !isFavorite(url) else { return }
        favorites.append(Favorite(url: url, title: title, order: (favorites.map(\.order).max() ?? -1) + 1))
        Task { await history.setBookmarked(url, true) }
        scheduleSave()
    }

    func removeFavorite(_ fav: Favorite) {
        favorites.removeAll { $0.id == fav.id }
        // Its tabs go back to being ordinary Today tabs.
        for tab in allTabs where tab.favoriteID == fav.id { tab.favoriteID = nil }
        Task { await history.setBookmarked(fav.url, false) }
        scheduleSave()
    }

    func moveFavorite(_ fav: Favorite, before target: Favorite?) {
        var sorted = sortedFavorites
        sorted.removeAll { $0.id == fav.id }
        let i = target.flatMap { t in sorted.firstIndex { $0.id == t.id } } ?? sorted.endIndex
        sorted.insert(fav, at: i)
        for j in sorted.indices { sorted[j].order = j }
        favorites = sorted
        scheduleSave()
    }

    var sortedFavorites: [Favorite] { favorites.sorted { $0.order < $1.order } }

    // MARK: Spaces

    @discardableResult
    func addSpace() -> Space {
        let used = Set(spaces.map(\.colorIndex))
        let color = (0..<SpacePalette.colors.count).first { !used.contains($0) } ?? spaces.count
        let space = Space(name: "Space \(regularSpaces.count + 1)", symbol: "circle.fill", colorIndex: color)
        spaces.insert(space, at: spaces.firstIndex { $0.isPrivate } ?? spaces.endIndex)
        scheduleSave()
        return space
    }

    func deleteSpace(_ space: Space) {
        if space.isPrivate { closePrivateSpace(); return }
        guard regularSpaces.count > 1, let i = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        space.allTabs.forEach { unload($0.id) }
        spaces.remove(at: i)
        for w in windows where w.selectedSpaceID == space.id { w.leaveSpace() }
        if settings.externalLinksSpaceID == space.id { settings.externalLinksSpaceID = nil }
        scheduleSave()
    }

    func openPrivateSpace() -> Space {
        if let privateSpace { return privateSpace }
        let space = Space(name: "Private", symbol: "eye.slash", colorIndex: 0, isPrivate: true)
        spaces.append(space)
        return space
    }

    /// Closes every private tab, which removes the Private space and throws its cookies away.
    func closePrivateSpace() {
        guard let space = privateSpace else { return }
        for tab in space.allTabs {
            for w in windows { w.cancelPrompts(for: tab.id) }
            unload(tab.id)
        }
        for w in windows where w.selectedSpaceID == space.id { w.leaveSpace() }
        spaces.removeAll { $0.id == space.id }
        engine.resetEphemeralProfile()
        scheduleSave()
    }

    // MARK: Archive

    /// Today tabs left alone for longer than the setting go to the archive, like Arc.
    func archiveStaleTabs(now: Date = .now) {
        let onScreen = Set(windows.compactMap { $0.currentTab?.id })
        for space in spaces where !space.isPrivate {
            let stale = space.today.filter {
                !onScreen.contains($0.id) && $0.id != space.selectedTabID
                    && now.timeIntervalSince($0.lastActive) > settings.archiveAfterHours * 3600
            }
            guard !stale.isEmpty else { continue }
            space.today.removeAll { t in stale.contains { $0.id == t.id } }
            for t in stale { unload(t.id) }
            archive.insert(contentsOf: stale, at: 0)
        }
        archive = Array(archive.prefix(500))
        scheduleSave()
    }

    func takeFromArchive(_ tab: BrowserTab, into space: Space) {
        archive.removeAll { $0.id == tab.id }
        tab.lastActive = .now
        space.today.insert(tab, at: 0)
        scheduleSave()
    }

    func clearArchive() {
        archive.removeAll()
        scheduleSave()
    }

    // MARK: Blocking and privacy

    func applyBlocking() {
        let s = settings
        let config = BlockingConfiguration(isEnabled: s.blockContent, ruleGroups: Set(s.filterGroups.map(\.rawValue)),
                                           allowlist: s.blockingDisabledHosts, declineCookieBanners: s.declineCookieBanners,
                                           globalPrivacyControl: globalPrivacyControl)
        blockingTask?.cancel()
        blockingTask = Task { [weak self] in
            guard let self else { return }
            await engine.applyBlocking(config)
            refreshFilterStatus()
            if s.blockContent, !filterStatus.isUpdating { await updateFilters(force: false) }
        }
    }

    /// Waits for blocking settings being applied right now.
    func blockingApplied() async { await blockingTask?.value }

    func updateFilters(force: Bool) async {
        guard !filterStatus.isUpdating else { return }
        filterStatus.isUpdating = true
        filterStatus.error = nil
        do {
            _ = try await engine.updateBlockingRules(force: force)
        } catch {
            filterStatus.error = "Couldn't update filters. \(error.localizedDescription)"
        }
        filterStatus.isUpdating = false
        refreshFilterStatus()
    }

    private func refreshFilterStatus() {
        let meta = ContentBlocker.shared.metadata
        filterStatus.lastUpdated = meta.lastUpdated
        filterStatus.ruleCount = settings.filterGroups.reduce(0) { $0 + (meta.ruleCounts[$1.rawValue] ?? 0) }
    }

    func clearWebsiteData() async {
        await engine.clearWebsiteData(for: .standard)
        for w in windows where w.currentTab?.isPrivate == false { w.currentController?.page.reload() }
    }

    func clearHistory() async {
        await history.clearAll()
        archive.removeAll()
        recentlyClosed.removeAll()
        scheduleSave()
    }

    func forgetPermissions(for host: String) {
        settings.sitePermissions[host] = nil
    }

    // MARK: Suggestions

    private func makeSuggestEngine() -> SuggestEngine {
        SuggestEngine(
            history: history,
            favorites: { [weak self] in await MainActor.run { self?.favorites ?? [] } },
            openTabs: { [weak self] in
                await MainActor.run {
                    guard let self else { return [] }
                    let window = self.activeWindow
                    let inPrivate = window?.currentSpace.isPrivate ?? false
                    return self.allTabs
                        .filter { $0.url != nil && $0.id != window?.currentTab?.id && (inPrivate || !$0.isPrivate) }
                        .sorted { $0.lastActive > $1.lastActive }
                        .map { OpenTabSnapshot(id: $0.id, url: $0.url!, title: $0.title) }
                }
            },
            searchEngine: settings.searchEngine,
            remoteSuggestionsEnabled: settings.remoteSuggestions,
            extraProviders: [
                CommandProvider(commands: { [weak self] in
                    await MainActor.run { self?.activeWindow?.availableCommands() ?? [] }
                }),
                ArchivedTabsProvider(tabs: { [weak self] in
                    await MainActor.run {
                        (self?.archive ?? []).compactMap { t in t.url.map { OpenTabSnapshot(id: t.id, url: $0, title: t.title) } }
                    }
                }),
            ])
    }

    // MARK: Persistence

    func scheduleSave() {
        guard snapshotURL != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard let snapshotURL else { return }
        for c in controllers.values { c.freeze() }
        // Next launch opens on the space the active window shows (never Private).
        let shown = activeWindow?.currentSpace
        let selected = shown.flatMap { $0.isPrivate ? nil : $0.id } ?? launchSpaceID
        launchSpaceID = selected
        let snap = BrowserSnapshot(spaces: regularSpaces.map(\.record), selectedSpaceID: selected,
                                   favorites: favorites, archive: archive.map(\.record), settings: settings,
                                   saved: savedSites)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: snapshotURL, options: .atomic)
        Task { await history.saveNow() }
    }
}

// MARK: - Extensions

/// Windows and tabs as extensions see them: each window's current space, its live tabs in order.
extension Library: EngineExtensionHost {
    var extensionWindows: [EngineWindowInfo] {
        let focused = activeWindow
        let ordered = focused.map { f in [f] + windows.filter { $0 !== f } } ?? windows
        return ordered.map { w in
            let space = w.currentSpace
            return EngineWindowInfo(id: w.id,
                                    pages: space.allTabs.compactMap { existingController(for: $0)?.page },
                                    activePage: w.currentTab.flatMap { existingController(for: $0)?.page },
                                    isFocused: w === focused, isPrivate: space.isPrivate,
                                    frame: w.nsWindow?.frame ?? .zero)
        }
    }

    /// chrome.sidePanel.open, or a toolbar click on an extension that asked for its panel instead.
    func showExtensionPanel(extensionID: String) -> Bool {
        let id = "ext:" + extensionID
        guard workbench.tool(id) != nil, let window = activeWindow else { return false }
        window.showPanel(id)
        return true
    }

    func focusExtensionWindow(_ id: UUID) {
        windows.first { $0.id == id }?.nsWindow?.makeKeyAndOrderFront(nil)
    }

    func openExtensionTab(url: URL?, windowID: UUID?, active: Bool) -> (any EnginePage)? {
        guard let window = windows.first(where: { $0.id == windowID }) ?? activeWindow else { return nil }
        // The page is made with its URL, so an extension page gets the web view setup it needs.
        let tab = BrowserTab(url: url, isPrivate: window.currentSpace.isPrivate)
        window.currentSpace.today.insert(tab, at: 0)
        let page = controller(for: tab).page
        if active { window.select(tab) }
        scheduleSave()
        return page
    }

    func activateExtensionTab(_ page: any EnginePage) {
        guard let tab = tab(showing: page) else { return }
        (window(showing: tab) ?? activeWindow)?.select(tab)
    }

    func closeExtensionTab(_ page: any EnginePage) {
        guard let tab = tab(showing: page) else { return }
        (window(showing: tab) ?? activeWindow)?.close(tab)
    }

    private func tab(showing page: any EnginePage) -> BrowserTab? {
        controllers.values.first { $0.page === page }?.tab
    }
}
