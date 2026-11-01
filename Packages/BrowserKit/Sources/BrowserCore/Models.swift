import Foundation
import Observation
import Suggest

@MainActor @Observable
public final class Tab: Identifiable {
    public let id: UUID
    public var url: URL?
    public var title: String
    public var isPinned: Bool
    public var lastActive: Date
    /// WKWebView.interactionState (back/forward list + scroll), saved when the web view is evicted.
    public var interactionState: Data?
    public var isPrivate: Bool

    // Live state mirrored from the web view (not persisted).
    public var estimatedProgress: Double = 0
    public var isLoading = false
    public var canGoBack = false
    public var canGoForward = false

    public init(id: UUID = UUID(), url: URL?, title: String = "", isPinned: Bool = false,
                lastActive: Date = .now, interactionState: Data? = nil, isPrivate: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.isPinned = isPinned
        self.lastActive = lastActive
        self.interactionState = interactionState
        self.isPrivate = isPrivate
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        if let url { return URLNormalizer.displayHost(url) }
        return "New Tab"
    }
}

@MainActor @Observable
public final class Space: Identifiable {
    public let id: UUID
    public var name: String
    /// SF Symbol name
    public var symbol: String
    /// Index into the app's space colour palette.
    public var colorIndex: Int
    public var pinned: [Tab]
    public var today: [Tab]
    public var selectedTabID: UUID?
    public var isSidebarOpen: Bool

    public init(id: UUID = UUID(), name: String, symbol: String = "circle.fill", colorIndex: Int = 0,
                pinned: [Tab] = [], today: [Tab] = [], selectedTabID: UUID? = nil, isSidebarOpen: Bool = true) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorIndex = colorIndex
        self.pinned = pinned
        self.today = today
        self.selectedTabID = selectedTabID
        self.isSidebarOpen = isSidebarOpen
    }

    public var allTabs: [Tab] { pinned + today }

    public var selectedTab: Tab? {
        allTabs.first { $0.id == selectedTabID }
    }
}

// MARK: - Settings

public struct BrowserSettings: Codable, Equatable, Sendable {
    public var searchEngine: SearchEngine = .google
    /// Send typed text to the search engine for suggestions. Off = local suggestions only.
    public var remoteSuggestions = true
    /// Today tabs untouched for this many hours move to the archive.
    public var archiveAfterHours: Double = 12
    /// Block ads and trackers with the built-in content rule list.
    public var blockContent = true
    /// Where links from other apps open.
    public var externalLinksSpaceID: UUID?

    public init() {}
}

// MARK: - Codable snapshot for persistence

struct TabRecord: Codable {
    var id: UUID, url: URL?, title: String, isPinned: Bool, lastActive: Date, interactionState: Data?
}

struct SpaceRecord: Codable {
    var id: UUID, name: String, symbol: String, colorIndex: Int
    var pinned: [TabRecord], today: [TabRecord], selectedTabID: UUID?, isSidebarOpen: Bool
}

struct BrowserSnapshot: Codable {
    var spaces: [SpaceRecord]
    var selectedSpaceID: UUID?
    var favorites: [Favorite]
    var archive: [TabRecord]
    var settings: BrowserSettings?
}

extension Tab {
    var record: TabRecord {
        TabRecord(id: id, url: url, title: title, isPinned: isPinned, lastActive: lastActive,
                  interactionState: interactionState)
    }
    convenience init(_ r: TabRecord) {
        self.init(id: r.id, url: r.url, title: r.title, isPinned: r.isPinned,
                  lastActive: r.lastActive, interactionState: r.interactionState)
    }
}

extension Space {
    var record: SpaceRecord {
        SpaceRecord(id: id, name: name, symbol: symbol, colorIndex: colorIndex,
                    pinned: pinned.map(\.record),
                    today: today.filter { !$0.isPrivate }.map(\.record),
                    selectedTabID: selectedTabID, isSidebarOpen: isSidebarOpen)
    }
    convenience init(_ r: SpaceRecord) {
        self.init(id: r.id, name: r.name, symbol: r.symbol, colorIndex: r.colorIndex,
                  pinned: r.pinned.map(Tab.init), today: r.today.map(Tab.init),
                  selectedTabID: r.selectedTabID, isSidebarOpen: r.isSidebarOpen)
    }
}
