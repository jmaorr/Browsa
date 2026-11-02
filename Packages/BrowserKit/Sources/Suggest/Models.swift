import Foundation

/// What a suggestion row does when tapped.
public enum SuggestionAction: Hashable, Sendable {
    case open(URL)
    case switchToTab(id: UUID, url: URL)
    case search(String)
    /// A browser action from the command bar ("Close other tabs", "Switch to Work"...).
    /// The id is interpreted by the app; the engine only matches and ranks it.
    case command(id: String)
}

public enum SuggestionKind: String, Hashable, Sendable, Comparable {
    case favorite, openTab, history, bookmark, seed, searchSuggestion, searchQuery, command, archived
    /// A site the search engine itself suggests for the query (Google "navigation" results).
    case remoteSite
    /// A Wikipedia article whose title matches what was typed.
    case entity

    /// Display grouping order when scores tie.
    var order: Int {
        switch self {
        case .favorite: 0
        case .openTab: 1
        case .bookmark: 2
        case .history: 3
        case .seed: 4
        case .searchQuery: 5
        case .searchSuggestion: 6
        case .command: 7
        case .archived: 8
        case .remoteSite: 9
        case .entity: 10
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

public struct Suggestion: Identifiable, Hashable, Sendable {
    public var id: String { "\(kind.rawValue)|\(dedupeKey)" }
    public let kind: SuggestionKind
    public let title: String
    public let subtitle: String?
    public let action: SuggestionAction
    /// Higher is better. Local providers set this; the engine adjusts it.
    public var score: Double
    /// Lowercased host+path used to merge duplicates across providers.
    public let dedupeKey: String

    public init(kind: SuggestionKind, title: String, subtitle: String? = nil,
                action: SuggestionAction, score: Double, dedupeKey: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.score = score
        switch action {
        case .open(let url), .switchToTab(_, let url):
            self.dedupeKey = dedupeKey ?? URLNormalizer.key(for: url)
        case .search(let q):
            self.dedupeKey = dedupeKey ?? "search:" + q.lowercased()
        case .command(let id):
            self.dedupeKey = dedupeKey ?? "cmd:" + id
        }
    }

    public var url: URL? {
        switch action {
        case .open(let u), .switchToTab(_, let u): u
        case .search, .command: nil
        }
    }
}

/// A single site the user has starred to appear in the new-tab sheet.
public struct Favorite: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var url: URL
    public var title: String
    /// Short label shown under the icon in the grid; falls back to the host.
    public var customName: String?
    public var order: Int

    public init(id: UUID = UUID(), url: URL, title: String, customName: String? = nil, order: Int) {
        self.id = id
        self.url = url
        self.title = title
        self.customName = customName
        self.order = order
    }

    public var displayName: String {
        customName ?? URLNormalizer.displayHost(url)
    }
}

/// One row of browsing history as the suggest engine sees it.
public struct HistoryEntry: Hashable, Sendable {
    public let url: URL
    public let title: String
    public let frecency: Double
    public let isBookmark: Bool

    public init(url: URL, title: String, frecency: Double, isBookmark: Bool = false) {
        self.url = url
        self.title = title
        self.frecency = frecency
        self.isBookmark = isBookmark
    }
}

public struct OpenTabSnapshot: Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let title: String
    public init(id: UUID, url: URL, title: String) {
        self.id = id
        self.url = url
        self.title = title
    }
}
