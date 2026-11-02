import Foundation

/// A command the command bar can run. The app decides what `id` does.
public struct BrowserCommand: Sendable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String?
    /// Extra words that should match ("tab", "remove"...).
    public let keywords: [String]

    public init(id: String, title: String, subtitle: String? = nil, keywords: [String] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
    }
}

/// Matches typed text against the commands available right now (they depend on the current tab
/// and spaces, so they're fetched per query).
public struct CommandProvider: SuggestionProvider {
    let commands: @Sendable () async -> [BrowserCommand]

    public init(commands: @escaping @Sendable () async -> [BrowserCommand]) {
        self.commands = commands
    }

    public func suggestions(for query: String, limit: Int) async -> [Suggestion] {
        // Commands need at least two letters so "g" still means google.com, not "Go to Settings".
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        return await commands().compactMap { c in
            let q = Matcher.titleQuality(query: query, title: c.title, keywords: c.keywords)
            guard q != .none else { return nil }
            return Suggestion(kind: .command, title: c.title, subtitle: c.subtitle,
                              action: .command(id: c.id), score: q.rawValue * 0.9)
        }
        .sorted { $0.score > $1.score }
        .prefix(limit).map { $0 }
    }
}

/// Archived tabs, so the command bar can bring one back.
public struct ArchivedTabsProvider: SuggestionProvider {
    let tabs: @Sendable () async -> [OpenTabSnapshot]

    public init(tabs: @escaping @Sendable () async -> [OpenTabSnapshot]) {
        self.tabs = tabs
    }

    public func suggestions(for query: String, limit: Int) async -> [Suggestion] {
        await tabs().compactMap { t in
            let q = Matcher.quality(query: query, url: t.url, title: t.title)
            guard q != .none else { return nil }
            return Suggestion(kind: .archived, title: t.title.isEmpty ? URLNormalizer.displayHost(t.url) : t.title,
                              subtitle: "Archived",
                              action: .command(id: "restore:" + t.id.uuidString), score: q.rawValue,
                              dedupeKey: "archived:" + URLNormalizer.key(for: t.url))
        }
        .prefix(limit).map { $0 }
    }
}
