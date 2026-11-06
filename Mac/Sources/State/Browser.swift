import AppKit
import Observation
import BrowserCore
import BrowserEngine
import Suggest

/// Everything one Browsa window shows: spaces, tabs, favourites, and the transient UI around them.
///
/// Engine-neutral: pages come from `engine`, and nothing here knows it's WebKit.
@MainActor @Observable
final class Browser {
    var spaces: [Space]
    var selectedSpaceID: UUID
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

    // MARK: Transient UI state

    /// The floating command bar, when it's open.
    var commandBar: CommandBarMode?
    /// Sidebar docked beside the page. Off, it slides over the page when the pointer reaches the edge.
    var isSidebarDocked: Bool { didSet { Preferences.sidebarDocked = isSidebarDocked } }
    /// The undocked sidebar is showing over the page.
    var isSidebarPeeking = false
    var sidebarWidth: CGFloat { didSet { Preferences.sidebarWidth = sidebarWidth } }
    /// Find on page, when the find bar is open.
    var find: FindState?
    /// Bumped to put the cursor in the find field.
    var findFocusRequest: UUID?
    var toast: String?
    var activePrompt: Prompt?
    var downloads: [EngineDownload] = []
    var isDownloadsPresented = false
    var isArchivePresented = false
    var filterStatus = FilterStatus()
    /// When and which way the space last changed, so tab lists cascade in from that side.
    private(set) var lastSpaceSwitch: SpaceSwitch?
    /// Tabs closed this session, newest last, for Shift-Cmd-T. Never private tabs.
    private(set) var recentlyClosed: [BrowserTab] = []

    let engine: any BrowserEngine
    let history: HistoryStore
    @ObservationIgnored private(set) var suggest: SuggestEngine!
    /// Live pages, by tab. The least recently used are unloaded past `capacity`.
    @ObservationIgnored private(set) var controllers: [UUID: TabController] = [:]
    @ObservationIgnored private var lru: [UUID] = []
    @ObservationIgnored private let capacity = 24
    @ObservationIgnored private let snapshotURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var blockingTask: Task<Void, Never>?
    @ObservationIgnored var promptQueue: [(Prompt, CheckedContinuation<EngineDialogResponse, Never>)] = []
    /// Kept so state written by a newer build round-trips; the Mac doesn't show Saved yet.
    @ObservationIgnored private var savedSites: [SavedSite] = []
    @ObservationIgnored private var spaceBeforePrivate: UUID?
    @ObservationIgnored var lastCookieToastURL: URL?

    init(engine: any BrowserEngine,
         history: HistoryStore = HistoryStore(fileURL: HistoryStore.defaultFileURL()),
         snapshotURL: URL? = Browser.defaultSnapshotURL()) {
        self.engine = engine
        self.history = history
        self.snapshotURL = snapshotURL
        isSidebarDocked = Preferences.sidebarDocked
        sidebarWidth = Preferences.sidebarWidth
        if let snapshotURL, let data = try? Data(contentsOf: snapshotURL),
           let snap = try? JSONDecoder().decode(BrowserSnapshot.self, from: data), !snap.spaces.isEmpty {
            spaces = snap.spaces.map(Space.init)
            selectedSpaceID = snap.selectedSpaceID ?? snap.spaces[0].id
            favorites = snap.favorites
            archive = snap.archive.map(BrowserTab.init)
            savedSites = snap.saved ?? []
            if let s = snap.settings { settings = s }
        } else {
            let personal = Space(name: "Personal", symbol: "house.fill", colorIndex: 0)
            spaces = [personal, Space(name: "Work", symbol: "briefcase.fill", colorIndex: 1)]
            selectedSpaceID = personal.id
            favorites = Self.starterFavorites
        }
        suggest = makeSuggestEngine()
        applyBlocking()
        archiveStaleTabs()
    }

    private static let starterFavorites: [Favorite] = [
        ("https://mail.google.com", "Gmail"), ("https://calendar.google.com", "Calendar"),
        ("https://www.youtube.com", "YouTube"), ("https://github.com", "GitHub"),
    ].enumerated().map { i, f in Favorite(url: URL(string: f.0)!, title: f.1, order: i) }

    static func defaultSnapshotURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "Browser/state.json")
    }

    // MARK: Selection

    var currentSpace: Space { spaces.first { $0.id == selectedSpaceID } ?? spaces[0] }
    var currentTab: BrowserTab? { currentSpace.selectedTab }
    var currentController: TabController? { currentTab.map(controller(for:)) }
    var regularSpaces: [Space] { spaces.filter { !$0.isPrivate } }
    var privateSpace: Space? { spaces.first { $0.isPrivate } }

    func space(containing tab: BrowserTab) -> Space? {
        spaces.first { $0.allTabs.contains { $0.id == tab.id } }
    }

    func select(_ tab: BrowserTab) {
        if let space = space(containing: tab) {
            if space.id != selectedSpaceID { selectSpace(space) }
            space.selectedTabID = tab.id
        }
        tab.lastActive = .now
        find = nil
        controllers[tab.id]?.recoverIfNeeded()
        scheduleSave()
    }

    func selectSpace(_ space: Space) {
        guard space.id != selectedSpaceID else { return }
        if space.isPrivate, !currentSpace.isPrivate { spaceBeforePrivate = selectedSpaceID }
        if let from = spaces.firstIndex(where: { $0.id == selectedSpaceID }),
           let to = spaces.firstIndex(where: { $0.id == space.id }) {
            lastSpaceSwitch = SpaceSwitch(at: .now, forward: to > from)
        }
        selectedSpaceID = space.id
        find = nil
        scheduleSave()
    }

    /// Pinned then today: the order the sidebar shows and Cmd-1…9 count.
    var orderedTabs: [BrowserTab] { currentSpace.pinned + currentSpace.today }

    func selectTab(number n: Int) {
        let tabs = orderedTabs
        guard !tabs.isEmpty else { return }
        let i = n >= 9 ? tabs.count - 1 : n - 1
        if tabs.indices.contains(i) { select(tabs[i]) }
    }

    func selectAdjacentTab(_ delta: Int) {
        let tabs = orderedTabs
        guard tabs.count > 1 else { return }
        guard let cur = currentTab, let i = tabs.firstIndex(where: { $0.id == cur.id }) else { select(tabs[0]); return }
        select(tabs[(i + delta + tabs.count) % tabs.count])
    }

    func selectAdjacentSpace(_ delta: Int) {
        guard spaces.count > 1, let i = spaces.firstIndex(where: { $0.id == selectedSpaceID }) else { return }
        let j = i + delta
        guard spaces.indices.contains(j) else { return }
        selectSpace(spaces[j])
    }

    func selectSpace(number n: Int) {
        if spaces.indices.contains(n - 1) { selectSpace(spaces[n - 1]) }
    }

    // MARK: Pages

    /// The live page for a tab, made (and restored) on first use.
    func controller(for tab: BrowserTab) -> TabController {
        touch(tab.id)
        if let c = controllers[tab.id] { return c }
        let c = TabController(tab: tab, browser: self) { delegate in
            engine.makePage(options: PageOptions(profile: tab.isPrivate ? .ephemeral : .standard,
                                                 url: tab.url, sessionState: tab.interactionState),
                            delegate: delegate)
        }
        controllers[tab.id] = c
        evictIfNeeded(keeping: tab.id)
        return c
    }

    /// Registers a page the engine made for a popup.
    func adopt(_ controller: TabController) {
        controllers[controller.tab.id] = controller
        touch(controller.tab.id)
        evictIfNeeded(keeping: controller.tab.id)
    }

    private func touch(_ id: UUID) {
        lru.removeAll { $0 == id }
        lru.append(id)
    }

    private func evictIfNeeded(keeping id: UUID) {
        while lru.count > capacity, let victim = lru.first(where: { $0 != id && $0 != currentTab?.id }) {
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

    @discardableResult
    func newTab(url: URL?, in space: Space? = nil, isPrivate: Bool = false,
                source: Frecency.VisitSource = .typed, select shouldSelect: Bool = true) -> BrowserTab {
        let requested = space ?? currentSpace
        let wantsPrivate = isPrivate || requested.isPrivate
        let target = wantsPrivate ? openPrivateSpace() : requested
        let tab = BrowserTab(url: nil, isPrivate: wantsPrivate)
        target.today.insert(tab, at: 0)
        if shouldSelect { select(tab) }
        if let url {
            let c = controller(for: tab)
            c.load(url, source: source)
        }
        scheduleSave()
        return tab
    }

    /// Cmd-click on a link: a new today tab just under the one it came from.
    func openInNewTab(_ url: URL, from opener: BrowserTab, foreground: Bool) {
        let space = space(containing: opener) ?? currentSpace
        let tab = BrowserTab(url: nil, isPrivate: opener.isPrivate)
        let after = space.today.firstIndex { $0.id == opener.id }.map { $0 + 1 } ?? 0
        space.today.insert(tab, at: after)
        controller(for: tab).load(url, source: .link)
        if foreground { select(tab) } else if let current = currentTab { touch(current.id) }
        scheduleSave()
    }

    /// A page opened a window. It becomes a tab right after its opener.
    func openPopup(from opener: BrowserTab, page: any EnginePage, url: URL?) -> TabController {
        let space = space(containing: opener) ?? currentSpace
        let tab = BrowserTab(url: url, isPrivate: opener.isPrivate)
        let after = space.today.firstIndex { $0.id == opener.id }.map { $0 + 1 } ?? 0
        space.today.insert(tab, at: after)
        let c = TabController(tab: tab, browser: self) { _ in page }
        adopt(c)
        select(tab)
        return c
    }

    /// A link from another app (when Browsa is the default browser).
    func openExternal(_ url: URL) {
        commandBar = nil
        let target = regularSpaces.first { $0.id == settings.externalLinksSpaceID }
            ?? (currentSpace.isPrivate ? regularSpaces[0] : currentSpace)
        newTab(url: url, in: target, source: .link)
    }

    /// Favourites behave like Arc's: one click goes to the tab that has the site, or opens one.
    func open(_ favorite: Favorite) {
        let key = URLNormalizer.key(for: favorite.url)
        if let existing = currentSpace.allTabs.first(where: { $0.url.map(URLNormalizer.key(for:)) == key }) {
            select(existing)
        } else {
            newTab(url: favorite.url, source: .bookmark)
        }
    }

    // MARK: Closing

    func close(_ tab: BrowserTab) {
        cancelPrompts(for: tab.id)
        if !tab.isPrivate, !tab.isPinned, tab.url != nil {
            controllers[tab.id]?.freeze()
            recentlyClosed.append(tab)
            if recentlyClosed.count > 30 { recentlyClosed.removeFirst() }
        }
        for space in spaces {
            if let i = space.today.firstIndex(where: { $0.id == tab.id }) {
                space.today.remove(at: i)
                if space.selectedTabID == tab.id {
                    // Arc moves to the tab below, then above.
                    let next = space.today.indices.contains(i) ? space.today[i] : (space.today.last ?? space.pinned.last)
                    space.selectedTabID = next?.id
                }
            } else if tab.isPinned, space.selectedTabID == tab.id {
                // Closing a pinned tab only unloads it, like Arc.
                space.selectedTabID = nil
            }
        }
        unload(tab.id)
        if let p = privateSpace, p.allTabs.isEmpty { closePrivateSpace() }
        scheduleSave()
    }

    func closeOtherTabs(than keep: BrowserTab) {
        for t in currentSpace.today where t.id != keep.id { close(t) }
    }

    /// Clears Today in the current space, like Arc's "Clear" button.
    func clearToday() {
        for t in currentSpace.today { close(t) }
    }

    func reopenClosedTab() {
        guard let tab = recentlyClosed.popLast() else { return }
        tab.lastActive = .now
        let target = currentSpace.isPrivate ? regularSpaces[0] : currentSpace
        target.today.insert(tab, at: 0)
        select(tab)
    }

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

    /// Drag and drop in the sidebar: `tab` lands just before `target` (or at the end of the section).
    func move(_ tab: BrowserTab, before target: BrowserTab?, pinned: Bool) {
        guard let from = space(containing: tab), !(tab.isPrivate && pinned) else { return }
        let to = target.flatMap(space(containing:)) ?? currentSpace
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
        if from.selectedTabID == tab.id, from.id != to.id { from.selectedTabID = from.today.first?.id ?? from.pinned.first?.id }
        scheduleSave()
    }

    func move(_ tab: BrowserTab, to space: Space) {
        guard let from = self.space(containing: tab), from.id != space.id, !space.isPrivate, !tab.isPrivate else { return }
        from.pinned.removeAll { $0.id == tab.id }
        from.today.removeAll { $0.id == tab.id }
        if from.selectedTabID == tab.id { from.selectedTabID = from.today.first?.id ?? from.pinned.first?.id }
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
        Task { await history.setBookmarked(fav.url, false) }
        scheduleSave()
    }

    func moveFavorite(_ fav: Favorite, before target: Favorite?) {
        var sorted = favorites.sorted { $0.order < $1.order }
        sorted.removeAll { $0.id == fav.id }
        let i = target.flatMap { t in sorted.firstIndex { $0.id == t.id } } ?? sorted.endIndex
        sorted.insert(fav, at: i)
        for j in sorted.indices { sorted[j].order = j }
        favorites = sorted
        scheduleSave()
    }

    var sortedFavorites: [Favorite] { favorites.sorted { $0.order < $1.order } }

    // MARK: Spaces

    func addSpace() {
        let used = Set(spaces.map(\.colorIndex))
        let color = (0..<SpacePalette.colors.count).first { !used.contains($0) } ?? spaces.count
        let space = Space(name: "Space \(regularSpaces.count + 1)", symbol: "circle.fill", colorIndex: color)
        spaces.insert(space, at: spaces.firstIndex { $0.isPrivate } ?? spaces.endIndex)
        selectSpace(space)
        scheduleSave()
    }

    func deleteSpace(_ space: Space) {
        if space.isPrivate { closePrivateSpace(); return }
        guard regularSpaces.count > 1, let i = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        space.allTabs.forEach { unload($0.id) }
        spaces.remove(at: i)
        if selectedSpaceID == space.id { selectedSpaceID = regularSpaces[0].id }
        if settings.externalLinksSpaceID == space.id { settings.externalLinksSpaceID = nil }
        scheduleSave()
    }

    private func openPrivateSpace() -> Space {
        if let privateSpace { return privateSpace }
        if !currentSpace.isPrivate { spaceBeforePrivate = selectedSpaceID }
        let space = Space(name: "Private", symbol: "eye.slash", colorIndex: 0, isPrivate: true)
        spaces.append(space)
        return space
    }

    /// Closes every private tab, which removes the Private space and throws its cookies away.
    func closePrivateSpace() {
        guard let space = privateSpace else { return }
        for tab in space.allTabs {
            cancelPrompts(for: tab.id)
            unload(tab.id)
        }
        if selectedSpaceID == space.id {
            let back = regularSpaces.first { $0.id == spaceBeforePrivate } ?? regularSpaces[0]
            lastSpaceSwitch = SpaceSwitch(at: .now, forward: false)
            selectedSpaceID = back.id
        }
        spaces.removeAll { $0.id == space.id }
        engine.resetEphemeralProfile()
        spaceBeforePrivate = nil
        scheduleSave()
    }

    // MARK: Archive

    /// Today tabs left alone for longer than the setting go to the archive, like Arc.
    func archiveStaleTabs(now: Date = .now) {
        for space in spaces where !space.isPrivate {
            let stale = space.today.filter {
                $0.id != space.selectedTabID && now.timeIntervalSince($0.lastActive) > settings.archiveAfterHours * 3600
            }
            guard !stale.isEmpty else { continue }
            space.today.removeAll { t in stale.contains { $0.id == t.id } }
            for t in stale { controllers[t.id]?.freeze(); unload(t.id) }
            archive.insert(contentsOf: stale, at: 0)
        }
        archive = Array(archive.prefix(500))
        scheduleSave()
    }

    func restoreFromArchive(_ tab: BrowserTab) {
        archive.removeAll { $0.id == tab.id }
        tab.lastActive = .now
        (currentSpace.isPrivate ? regularSpaces[0] : currentSpace).today.insert(tab, at: 0)
        select(tab)
    }

    // MARK: Toast

    func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Blocking

    func applyBlocking() {
        let s = settings
        let config = BlockingConfiguration(isEnabled: s.blockContent, ruleGroups: Set(s.filterGroups.map(\.rawValue)),
                                           allowlist: s.blockingDisabledHosts, declineCookieBanners: s.declineCookieBanners)
        blockingTask?.cancel()
        blockingTask = Task { [weak self] in
            guard let self else { return }
            await engine.applyBlocking(config)
            refreshFilterStatus()
            if s.blockContent, !filterStatus.isUpdating { await updateFilters(force: false) }
        }
    }

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

    var blockingDisabledForCurrentSite: Bool { settings.blockingDisabled(for: currentTab?.url?.host()) }

    func toggleBlockingForCurrentSite() {
        guard let tab = currentTab, let host = tab.url?.host()?.lowercased() else { return }
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if settings.blockingDisabled(for: host) {
            settings.blockingDisabledHosts = settings.blockingDisabledHosts.filter { host != $0 && !host.hasSuffix("." + $0) }
            showToast("Blockers on for \(site)")
        } else {
            settings.blockingDisabledHosts.insert(site)
            showToast("Blockers off for \(site)")
        }
        Task { @MainActor in
            await blockingTask?.value
            controller(for: tab).page.reload()
        }
    }

    func clearWebsiteData() async {
        await engine.clearWebsiteData(for: .standard)
        if currentTab?.isPrivate == false { currentController?.page.reload() }
        showToast("Website data cleared")
    }

    // MARK: Suggestions

    private func makeSuggestEngine() -> SuggestEngine {
        SuggestEngine(
            history: history,
            favorites: { [weak self] in await MainActor.run { self?.favorites ?? [] } },
            openTabs: { [weak self] in
                await MainActor.run {
                    guard let self else { return [] }
                    let inPrivate = self.currentSpace.isPrivate
                    return self.spaces.flatMap(\.allTabs)
                        .filter { $0.url != nil && $0.id != self.currentTab?.id && (inPrivate || !$0.isPrivate) }
                        .sorted { $0.lastActive > $1.lastActive }
                        .map { OpenTabSnapshot(id: $0.id, url: $0.url!, title: $0.title) }
                }
            },
            searchEngine: settings.searchEngine,
            remoteSuggestionsEnabled: settings.remoteSuggestions,
            extraProviders: [
                CommandProvider(commands: { [weak self] in await MainActor.run { self?.availableCommands() ?? [] } }),
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
        let selected = currentSpace.isPrivate ? (spaceBeforePrivate ?? regularSpaces.first?.id) : selectedSpaceID
        let snap = BrowserSnapshot(spaces: regularSpaces.map(\.record), selectedSpaceID: selected,
                                   favorites: favorites, archive: archive.map(\.record), settings: settings,
                                   saved: savedSites)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: snapshotURL, options: .atomic)
        Task { await history.saveNow() }
    }
}

// MARK: - Small types

enum CommandBarMode: Equatable {
    /// Cmd-T: opens what you pick in a new tab.
    case newTab
    /// Cmd-L or a click on the address: replaces the current page.
    case editCurrent
}

struct SpaceSwitch: Equatable {
    let at: Date
    let forward: Bool
}

struct FindState: Equatable {
    var text = ""
    var found: Bool?
}

/// Window preferences that aren't part of the synced browser state.
enum Preferences {
    private static let d = UserDefaults.standard

    static var sidebarDocked: Bool {
        get { d.object(forKey: "sidebarDocked") as? Bool ?? true }
        set { d.set(newValue, forKey: "sidebarDocked") }
    }

    static var sidebarWidth: CGFloat {
        get { (d.object(forKey: "sidebarWidth") as? Double).map { CGFloat($0) } ?? 260 }
        set { d.set(Double(newValue), forKey: "sidebarWidth") }
    }

    /// Page zoom per site, like Safari remembers it.
    static func zoom(for host: String) -> Double {
        (d.dictionary(forKey: "siteZoom")?[host] as? Double) ?? 1
    }

    static func setZoom(_ zoom: Double, for host: String) {
        var all = d.dictionary(forKey: "siteZoom") ?? [:]
        all[host] = abs(zoom - 1) < 0.01 ? nil : zoom
        d.set(all, forKey: "siteZoom")
    }
}
