import Foundation

/// Simple HistoryIndex backed by an array. Used by tests and previews; the app uses
/// BrowserCore.HistoryStore, which persists to disk.
public actor InMemoryHistoryIndex: HistoryIndex {
    public private(set) var entries: [HistoryEntry]

    public init(_ entries: [HistoryEntry] = []) {
        self.entries = entries
    }

    public func replace(_ entries: [HistoryEntry]) {
        self.entries = entries
    }

    public func candidates(matching query: String, limit: Int) async -> [HistoryEntry] {
        entries
            .filter { Matcher.quality(query: query, url: $0.url, title: $0.title) != .none }
            .sorted { $0.frecency > $1.frecency }
            .prefix(limit).map { $0 }
    }

    public func topSites(limit: Int) async -> [HistoryEntry] {
        entries.sorted { $0.frecency > $1.frecency }.prefix(limit).map { $0 }
    }
}
