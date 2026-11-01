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
    public var archive: [Tab] = []

    // Transient UI state
    public var isNewTabSheetPresented = false
    /// When the sheet is opened from the address pill to edit the current URL rather than for a new tab.
    public var newTabSheetEditsCurrentTab = false
    public var isTabSwitcherPresented = false
    public var isSettingsPresented = false
    public var isCommandBarPresented = false

    public var settings = BrowserSettings() {
        didSet {
            guard settings != oldValue else { return }
            if settings.searchEngine != oldValue.searchEngine || settings.remoteSuggestions != oldValue.remoteSuggestions {
                suggest = makeSuggestEngine()
            }
            if settings.blockContent != oldValue.blockContent { applyContentBlocking() }
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
            archive = snap.archive.map(Tab.init)
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

    public var currentTab: Tab? { currentSpace.selectedTab }

    public func session(for tab: Tab) -> TabSession {
        pool.session(for: tab, browser: self)
    }

    public func select(_ tab: Tab) {
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
    public func presentNewTab() {
        newTabSheetEditsCurrentTab = false
        isNewTabSheetPresented = true
    }

    /// Tap on the address pill / field.
    public func presentAddressEditor() {
        newTabSheetEditsCurrentTab = currentTab != nil
        isNewTabSheetPresented = true
    }

    @discardableResult
    public func newTab(url: URL?, in space: Space? = nil, isPrivate: Bool = false,
                       source: Frecency.VisitSource = .typed) -> Tab {
        let space = space ?? currentSpace
        let tab = Tab(url: nil, isPrivate: isPrivate)
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
        }
    }

    private func navigate(to url: URL, reuseCurrent: Bool, source: Frecency.VisitSource) {
        if reuseCurrent, let tab = currentTab {
            session(for: tab).load(url, source: source)
        } else {
            newTab(url: url, source: source)
        }
    }

    func openPopup(url: URL, configuration: WKWebViewConfiguration, from opener: Tab) -> WKWebView {
        let space = spaces.first { $0.allTabs.contains { $0.id == opener.id } } ?? currentSpace
        let tab = Tab(url: url, isPrivate: opener.isPrivate)
        space.today.insert(tab, at: 0)
        let s = TabSession(tab: tab, configuration: configuration, browser: self, loadInitial: false)
        pool.adopt(s)
        select(tab)
        return s.webView
    }

    // MARK: Tab management

    public func close(_ tab: Tab) {
        for space in spaces {
            if let i = space.today.firstIndex(where: { $0.id == tab.id }) {
                space.today.remove(at: i)
                if space.selectedTabID == tab.id {
                    let next: Tab? = space.today.indices.contains(i) ? space.today[i] : (space.today.last ?? space.pinned.last)
                    space.selectedTabID = next?.id
                }
            } else if tab.isPinned, space.selectedTabID == tab.id {
                // Closing a pinned tab just unloads it, like Arc.
                space.selectedTabID = nil
            }
        }
        pool.remove(tab.id)
        scheduleSave()
    }

    public func togglePinned(_ tab: Tab) {
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

    public func restoreFromArchive(_ tab: Tab) {
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
            remoteSuggestionsEnabled: settings.remoteSuggestions)
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
