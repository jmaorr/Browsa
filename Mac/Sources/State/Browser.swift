import AppKit
import Observation
import BrowserCore
import BrowserEngine
import Suggest
import SwiftUI

/// One Browsa window: which space and tab it shows, and the transient UI around them.
/// Spaces, tabs, favourites and settings live in the shared `Library`.
@MainActor @Observable
final class Browser {
    let library: Library
    /// Stable for the window's life, for extensions.
    let id = UUID()
    var selectedSpaceID: UUID
    /// The tab this window shows in each space it has visited. Two windows never show the same tab.
    private var tabSelection: [UUID: UUID] = [:]
    /// The AppKit window, for focusing and for matching key events to this browser.
    @ObservationIgnored weak var nsWindow: NSWindow?

    // MARK: Transient UI state

    /// The floating command bar, when it's open.
    var commandBar: CommandBarMode?
    /// Sidebar docked beside the page. Off, it slides over the page when the pointer reaches the edge.
    var isSidebarDocked: Bool { didSet { Preferences.sidebarDocked = isSidebarDocked } }
    /// The undocked sidebar is showing over the page.
    var isSidebarPeeking = false
    /// True while the sidebar docks or hides. The page keeps one size meanwhile and resizes once.
    private(set) var isSidebarMoving = false
    var sidebarWidth: CGFloat { didSet { Preferences.sidebarWidth = sidebarWidth } }
    /// Find on page, when the find bar is open.
    var find: FindState?
    /// Bumped to put the cursor in the find field.
    var findFocusRequest: UUID?
    var toast: String?
    var activePrompt: Prompt?
    /// Reader, when it's showing over the current tab.
    var reader: ReaderSession?
    var isArchivePresented = false
    /// When and which way the space last changed, so tab lists cascade in from that side.
    private(set) var lastSpaceSwitch: SpaceSwitch?
    /// The right-hand panel each space last showed. It pushes the page over, never covers it.
    private var panels: [UUID: String] = [:]
    var panelWidth: CGFloat { didSet { Preferences.panelWidth = panelWidth } }
    /// The first-launch intro's current phase, while it plays.
    var intro: IntroPhase?
    @ObservationIgnored var introTask: Task<Void, Never>?
    /// The page card's view, so the intro can settle exactly onto it.
    @ObservationIgnored weak var pageCardView: NSView?

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarMoveTask: Task<Void, Never>?
    @ObservationIgnored var promptQueue: [(Prompt, CheckedContinuation<EngineDialogResponse, Never>)] = []
    @ObservationIgnored private var spaceBeforePrivate: UUID?
    @ObservationIgnored var lastCookieToastURL: URL?

    init(library: Library) {
        self.library = library
        isSidebarDocked = Preferences.sidebarDocked
        sidebarWidth = Preferences.sidebarWidth
        panelWidth = Preferences.panelWidth
        let request = library.takeWindowRequest()
        let isFirst = library.windows.isEmpty
        let launch = library.regularSpaces.first { $0.id == library.launchSpaceID } ?? library.regularSpaces[0]
        let nearby = library.activeWindow.map { $0.currentSpace }.flatMap { $0.isPrivate ? nil : $0 }
        selectedSpaceID = (isFirst ? launch : nearby ?? launch).id
        library.register(self)

        switch request {
        case .tab(let tab):
            if let space = library.space(containing: tab) {
                library.window(showing: tab)?.moveOff(tab, in: space)
                select(tab)
            }
        case .url(let url):
            newTab(url: url)
        case .privateTab:
            newTab(url: nil, isPrivate: true)
            commandBar = .editCurrent
        case nil:
            if isFirst {
                // The first window picks up where Browsa left off. The very first launch says hello.
                resolveSelection(in: currentSpace)
                let env = ProcessInfo.processInfo.environment
                if env["BROWSA_WELCOME"] == "1" || (!Preferences.hasSeenWelcome && env["BROWSA_SNAPSHOT"] == nil) {
                    openWelcome(playingIntro: true)
                }
            } else {
                commandBar = .newTab
            }
        }
    }

    // MARK: Shared state, as this window sees it

    var spaces: [Space] { library.spaces }
    var regularSpaces: [Space] { library.regularSpaces }
    var privateSpace: Space? { library.privateSpace }
    var favorites: [Favorite] { library.favorites }
    var sortedFavorites: [Favorite] { library.sortedFavorites }
    var archive: [BrowserTab] { library.archive }
    var settings: BrowserSettings {
        get { library.settings }
        set { library.settings = newValue }
    }
    var downloads: [EngineDownload] { library.downloads }
    var filterStatus: FilterStatus { library.filterStatus }
    var recentlyClosed: [BrowserTab] { library.recentlyClosed }
    var engine: any BrowserEngine { library.engine }
    var history: HistoryStore { library.history }
    var suggest: SuggestEngine { library.suggest }

    func space(containing tab: BrowserTab) -> Space? { library.space(containing: tab) }
    func controller(for tab: BrowserTab) -> TabController { library.controller(for: tab) }
    func isFavorite(_ url: URL) -> Bool { library.isFavorite(url) }
    func addFavorite(url: URL, title: String) { library.addFavorite(url: url, title: title) }
    func removeFavorite(_ fav: Favorite) { library.removeFavorite(fav) }
    func moveFavorite(_ fav: Favorite, before target: Favorite?) { library.moveFavorite(fav, before: target) }
    func togglePinned(_ tab: BrowserTab) { library.togglePinned(tab) }
    func move(_ tab: BrowserTab, to space: Space) { library.move(tab, to: space) }
    func move(_ tab: BrowserTab, before target: BrowserTab?, pinned: Bool) {
        library.move(tab, before: target, pinned: pinned, fallback: currentSpace)
    }
    func deleteSpace(_ space: Space) { library.deleteSpace(space) }
    func closePrivateSpace() { library.closePrivateSpace() }
    func forgetPermissions(for host: String) { library.forgetPermissions(for: host) }
    func updateFilters(force: Bool) async { await library.updateFilters(force: force) }
    func scheduleSave() { library.scheduleSave() }
    func saveNow() { library.saveNow() }

    // MARK: Selection

    var currentSpace: Space { spaces.first { $0.id == selectedSpaceID } ?? regularSpaces[0] }

    var currentTab: BrowserTab? {
        let space = currentSpace
        guard let id = tabSelection[space.id] else { return nil }
        return space.allTabs.first { $0.id == id }
    }

    var currentController: TabController? { currentTab.map(controller(for:)) }

    /// The tab this window shows (or last showed) in a space.
    func selectedTabID(in space: Space) -> UUID? { tabSelection[space.id] }

    /// Shows a tab. If another window already shows it, that window comes forward instead, like Arc.
    func select(_ tab: BrowserTab) {
        if let other = library.window(showing: tab), other !== self {
            other.nsWindow?.makeKeyAndOrderFront(nil)
            return
        }
        guard let space = space(containing: tab) else { return }
        if space.id != selectedSpaceID { selectSpace(space, resolving: false) }
        setSelection(tab, in: space)
        tab.lastActive = .now
        find = nil
        reader = nil
        library.existingController(for: tab)?.recoverIfNeeded()
        scheduleSave()
    }

    func selectSpace(_ space: Space) { selectSpace(space, resolving: true) }

    private func selectSpace(_ space: Space, resolving: Bool) {
        guard space.id != selectedSpaceID else { return }
        if space.isPrivate, !currentSpace.isPrivate { spaceBeforePrivate = selectedSpaceID }
        if let from = spaces.firstIndex(where: { $0.id == selectedSpaceID }),
           let to = spaces.firstIndex(where: { $0.id == space.id }) {
            lastSpaceSwitch = SpaceSwitch(at: .now, forward: to > from)
        }
        selectedSpaceID = space.id
        if resolving { resolveSelection(in: space) }
        find = nil
        reader = nil
        toast = nil
        scheduleSave()
    }

    /// First visit to a space in this window: show the tab the space last had, unless another window has it.
    private func resolveSelection(in space: Space) {
        guard tabSelection[space.id] == nil, let tab = space.selectedTab, library.window(showing: tab) == nil else { return }
        tabSelection[space.id] = tab.id
    }

    private func setSelection(_ tab: BrowserTab?, in space: Space) {
        tabSelection[space.id] = tab?.id
        // Remembered with the space, for the next launch.
        space.selectedTabID = tab?.id
        if let tab, let c = library.existingController(for: tab) { engine.pageDidBecomeActive(c.page) }
    }

    /// `tab` is going away from this window (closed, moved, or opened in another window).
    /// Arc moves to the tab below, then above.
    func moveOff(_ tab: BrowserTab, in space: Space) {
        guard tabSelection[space.id] == tab.id else { return }
        if selectedSpaceID == space.id { find = nil; reader = nil }
        guard !tab.isPinned, let i = space.today.firstIndex(where: { $0.id == tab.id }) else {
            // Leaving a pinned tab only unloads it, like Arc.
            setSelection(nil, in: space)
            return
        }
        let elsewhere = Set(library.windows.filter { $0 !== self }.compactMap { $0.currentTab?.id })
        let free = { (t: BrowserTab) in !elsewhere.contains(t.id) && t.id != tab.id }
        let next = space.today[(i + 1)...].first(where: free)
            ?? space.today[..<i].reversed().first(where: free)
            ?? space.pinned.last(where: free)
        setSelection(next, in: space)
    }

    /// A tab this window showed was dragged into another space.
    func tabLeft(_ tab: BrowserTab, space: Space) {
        guard tabSelection[space.id] == tab.id else { return }
        let elsewhere = Set(library.windows.filter { $0 !== self }.compactMap { $0.currentTab?.id })
        setSelection(space.allTabs.first { !elsewhere.contains($0.id) }, in: space)
    }

    /// The space this window shows was deleted or closed.
    func leaveSpace() {
        tabSelection[selectedSpaceID] = nil
        let back = regularSpaces.first { $0.id == spaceBeforePrivate && $0.id != selectedSpaceID }
            ?? regularSpaces.first { $0.id != selectedSpaceID } ?? regularSpaces[0]
        lastSpaceSwitch = SpaceSwitch(at: .now, forward: false)
        selectedSpaceID = back.id
        spaceBeforePrivate = nil
        resolveSelection(in: back)
        find = nil
        reader = nil
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
        let spaces = shownSpaces
        guard spaces.count > 1, let i = spaces.firstIndex(where: { $0.id == selectedSpaceID }) else { return }
        let j = i + delta
        guard spaces.indices.contains(j) else { return }
        selectSpace(spaces[j])
    }

    func selectSpace(number n: Int) {
        let spaces = shownSpaces
        if spaces.indices.contains(n - 1) { selectSpace(spaces[n - 1]) }
    }

    /// The spaces the switcher shows: the Agent space only while it's in use (or you're in it).
    var shownSpaces: [Space] {
        spaces.filter { $0.id == selectedSpaceID || library.agents.showsInSidebar($0) }
    }

    // MARK: Opening tabs

    @discardableResult
    func newTab(url: URL?, in space: Space? = nil, isPrivate: Bool = false,
                source: Frecency.VisitSource = .typed, select shouldSelect: Bool = true) -> BrowserTab {
        let tab = library.insertTab(url: url, in: space ?? currentSpace, isPrivate: isPrivate, source: source)
        if shouldSelect { select(tab) }
        return tab
    }

    /// A link from another app (when Browsa is the default browser).
    func openExternal(_ url: URL) {
        commandBar = nil
        let target = regularSpaces.first { $0.id == settings.externalLinksSpaceID }
            ?? (currentSpace.isPrivate ? regularSpaces[0] : currentSpace)
        newTab(url: url, in: target, source: .link)
    }

    /// Favourites behave like Arc's: the tile holds its own tab, kept out of the Today list. One
    /// click goes back to that tab, or to a tab already showing the site, or opens one.
    func open(_ favorite: Favorite) {
        if let owned = currentSpace.today.first(where: { $0.favoriteID == favorite.id }) {
            select(owned)
            return
        }
        let key = URLNormalizer.key(for: favorite.url)
        if let existing = currentSpace.allTabs.first(where: { $0.url.map(URLNormalizer.key(for:)) == key }) {
            select(existing)
        } else {
            let tab = newTab(url: favorite.url, source: .bookmark)
            tab.favoriteID = favorite.id
            scheduleSave()
        }
    }

    /// Moves a tab out into a window of its own.
    func openInNewWindow(_ tab: BrowserTab) {
        library.openWindow(.tab(tab))
    }

    // MARK: Closing

    func close(_ tab: BrowserTab) { library.close(tab) }

    func closeOtherTabs(than keep: BrowserTab) {
        for t in currentSpace.listedToday where t.id != keep.id { close(t) }
    }

    /// Clears Today in the current space, like Arc's "Clear" button.
    func clearToday() {
        for t in currentSpace.listedToday { close(t) }
    }

    func reopenClosedTab() {
        guard let tab = library.popRecentlyClosed() else { return }
        tab.lastActive = .now
        let target = currentSpace.isPrivate ? regularSpaces[0] : currentSpace
        target.today.insert(tab, at: 0)
        select(tab)
    }

    // MARK: Spaces

    func addSpace() {
        selectSpace(library.addSpace())
    }

    // MARK: Archive

    func restoreFromArchive(_ tab: BrowserTab) {
        library.takeFromArchive(tab, into: currentSpace.isPrivate ? regularSpaces[0] : currentSpace)
        select(tab)
    }

    // MARK: Sidebar

    func toggleSidebar() {
        // The page holds its width while the sidebar moves, then resizes once (see PageHost).
        sidebarMoveTask?.cancel()
        isSidebarMoving = true
        sidebarMoveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Motion.dockDuration * 1000) + 40))
            guard !Task.isCancelled else { return }
            self?.isSidebarMoving = false
        }
        isSidebarDocked.toggle()
        isSidebarPeeking = false
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
            await library.blockingApplied()
            controller(for: tab).page.reload()
        }
    }

    func clearWebsiteData() async {
        await library.clearWebsiteData()
        showToast("Website data cleared")
    }
}

// MARK: - Small types

enum CommandBarMode: Equatable {
    /// Cmd-T: opens what you pick in a new tab.
    case newTab
    /// Cmd-L or a click on the address: replaces the current page.
    case editCurrent
    /// Cmd-K: tools and commands first, the web only as a fallback.
    case commands
}

struct SpaceSwitch: Equatable {
    let at: Date
    let forward: Bool
}

struct FindState: Equatable {
    var text = ""
    var found: Bool?
}

/// What a new window should show first.
enum WindowRequest {
    case tab(BrowserTab)
    case url(URL)
    case privateTab
}

/// Preferences that aren't part of the synced browser state.
enum Preferences {
    private static var d: UserDefaults { .standard }

    /// Set once the welcome tab has opened, so the intro plays on first launch only.
    static var hasSeenWelcome: Bool {
        get { d.bool(forKey: "hasSeenWelcome") }
        set { d.set(newValue, forKey: "hasSeenWelcome") }
    }

    /// Extension ids pinned to the address pill; nil until the user first pins or unpins one.
    static var pinnedExtensions: Set<String>? {
        get { (d.array(forKey: "pinnedExtensions") as? [String]).map(Set.init) }
        set { d.set(newValue.map { Array($0).sorted() }, forKey: "pinnedExtensions") }
    }

    /// The Settings tab to show next, so other places can open Settings on a given tab.
    static var settingsTab: String {
        get { d.string(forKey: "settingsTab") ?? "general" }
        set { d.set(newValue, forKey: "settingsTab") }
    }

    static var panelWidth: CGFloat {
        get { (d.object(forKey: "panelWidth") as? Double).map { CGFloat($0) } ?? 320 }
        set { d.set(Double(newValue), forKey: "panelWidth") }
    }

    static var sidebarDocked: Bool {
        get { d.object(forKey: "sidebarDocked") as? Bool ?? true }
        set { d.set(newValue, forKey: "sidebarDocked") }
    }

    static var sidebarWidth: CGFloat {
        get { (d.object(forKey: "sidebarWidth") as? Double).map { CGFloat($0) } ?? 260 }
        set { d.set(Double(newValue), forKey: "sidebarWidth") }
    }

    /// On by default: asking sites not to sell or share your data costs nothing.
    static var globalPrivacyControl: Bool {
        get { d.object(forKey: "globalPrivacyControl") as? Bool ?? true }
        set { d.set(newValue, forKey: "globalPrivacyControl") }
    }

    static var clearDataOnQuit: Bool {
        get { d.bool(forKey: "clearDataOnQuit") }
        set { d.set(newValue, forKey: "clearDataOnQuit") }
    }

    /// Safari web extensions installed on this Mac (1Password for Safari and the like). On in Debug builds.
    static var useSafariExtensions: Bool {
        get {
            #if DEBUG
            d.object(forKey: "useSafariExtensions") as? Bool ?? true
            #else
            d.bool(forKey: "useSafariExtensions")
            #endif
        }
        set { d.set(newValue, forKey: "useSafariExtensions") }
    }

    /// Inspect Element in the page's context menu. On in Debug builds.
    static var developerTools: Bool {
        get {
            #if DEBUG
            d.object(forKey: "developerTools") as? Bool ?? true
            #else
            d.bool(forKey: "developerTools")
            #endif
        }
        set { d.set(newValue, forKey: "developerTools") }
    }

    /// Reader text size, shared by every article.
    static var readerScale: Double {
        get { d.object(forKey: "readerScale") as? Double ?? 1 }
        set { d.set(newValue, forKey: "readerScale") }
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

// MARK: - Right panel

extension Browser {
    /// The tool showing in the right-hand panel, by `Tool.id`, for this space.
    var panel: String? {
        get { panels[selectedSpaceID] }
        set {
            panels[selectedSpaceID] = newValue
            if let newValue { Preferences.lastPanelTool = newValue }
        }
    }

    /// ⌥⌘S: shows the tool this window last had (Notes the first time), or hides the panel.
    func togglePanel() {
        withAnimation(Motion.dock) {
            panel = panel == nil ? (library.workbench.tool(Preferences.lastPanelTool)?.id ?? "notes") : nil
        }
    }

    /// Opens a tool in the panel, or hides the panel if that tool is already showing.
    func showPanel(_ id: String, toggles: Bool = false) {
        withAnimation(Motion.dock) { panel = toggles && panel == id ? nil : id }
    }

    /// Sets the panel a space opens with, without touching the space on screen.
    func setPanel(_ id: String, for space: Space, ifUnset: Bool) {
        if ifUnset, panels[space.id] != nil { return }
        panels[space.id] = id
    }

    /// An agent is waiting on you: bring up the Agents panel here, without taking the keyboard.
    func showAgentsPanel() {
        if panel != "agents" { showPanel("agents") }
    }
}

extension Preferences {
    static var lastPanelTool: String {
        get { UserDefaults.standard.string(forKey: "lastPanelTool") ?? "notes" }
        set { UserDefaults.standard.set(newValue, forKey: "lastPanelTool") }
    }
}
