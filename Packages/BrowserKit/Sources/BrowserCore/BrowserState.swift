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
    @ObservationIgnored var toastTask: Task<Void, Never>?
    /// Tabs closed this session, newest last, for Cmd-Shift-T. In memory only, never private tabs.
    public private(set) var recentlyClosed: [BrowserTab] = []
    /// Small pictures of each tab's page for the tab grid, taken as you leave a tab.
    /// Saved to disk except for private tabs; a tab without one shows its icon.
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

    /// When and which way the space last changed, so tab lists can cascade in from that side.
    public struct SpaceSwitch: Equatable, Sendable {
        public let at: Date
        public let forward: Bool
    }
    public private(set) var lastSpaceSwitch: SpaceSwitch?
    /// The tab gallery is over the page, so the page's colour shouldn't surround it.
    public var tabGridCoversPage = false

    public let history: HistoryStore
    @ObservationIgnored let pool = WebViewPool()
    @ObservationIgnored public private(set) var suggest: SuggestEngine!
    @ObservationIgnored private let snapshotURL: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let thumbnailStore: ThumbnailStore?

    public init(history: HistoryStore = HistoryStore(fileURL: HistoryStore.defaultFileURL()),
                snapshotURL: URL? = BrowserState.defaultSnapshotURL(),
                thumbnailStore: ThumbnailStore? = ThumbnailStore()) {
        self.history = history
        self.snapshotURL = snapshotURL
        self.thumbnailStore = thumbnailStore
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
        loadSavedThumbnails()
    }

    private func loadSavedThumbnails() {
        guard let thumbnailStore else { return }
        let ids = Set((spaces.flatMap(\.allTabs) + archive).map(\.id))
        Task {
            let saved = await Task.detached(priority: .utility) { thumbnailStore.loadAll(keeping: ids) }.value
            for (id, data) in saved where thumbnails[id] == nil {
                thumbnails[id] = UIImage(data: data)
            }
        }
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
        if let from = spaces.firstIndex(where: { $0.id == selectedSpaceID }),
           let to = spaces.firstIndex(where: { $0.id == space.id }), from != to {
            lastSpaceSwitch = SpaceSwitch(at: .now, forward: to > from)
        }
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
        if let thumbnailStore {
            let id = tab.id
            Task.detached(priority: .utility) { thumbnailStore.remove(id) }
        }
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
        guard !tab.isPrivate, let thumbnailStore, let data = image.jpegData(compressionQuality: 0.7) else { return }
        let id = tab.id
        Task.detached(priority: .utility) { thumbnailStore.save(data, for: id) }
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
