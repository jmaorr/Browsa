import Foundation

/// A source of suggestions. Local providers must be fast (< 20 ms); remote ones are awaited
/// separately by the engine so they never block the first paint.
public protocol SuggestionProvider: Sendable {
    var isRemote: Bool { get }
    func suggestions(for query: String, limit: Int) async -> [Suggestion]
}

public extension SuggestionProvider {
    var isRemote: Bool { false }
}

// MARK: - Favourites

public struct FavoritesProvider: SuggestionProvider {
    let favorites: @Sendable () async -> [Favorite]

    public init(favorites: @escaping @Sendable () async -> [Favorite]) {
        self.favorites = favorites
    }

    public func suggestions(for query: String, limit: Int) async -> [Suggestion] {
        await favorites().compactMap { fav in
            let q = Matcher.quality(query: query, url: fav.url, title: fav.displayName + " " + fav.title)
            guard q != .none else { return nil }
            return Suggestion(kind: .favorite, title: fav.displayName,
                              subtitle: URLNormalizer.displayHost(fav.url),
                              action: .open(fav.url), score: q.rawValue)
        }
        .prefix(limit).map { $0 }
    }
}

// MARK: - Open tabs

public struct OpenTabsProvider: SuggestionProvider {
    let tabs: @Sendable () async -> [OpenTabSnapshot]

    public init(tabs: @escaping @Sendable () async -> [OpenTabSnapshot]) {
        self.tabs = tabs
    }

    public func suggestions(for query: String, limit: Int) async -> [Suggestion] {
        await tabs().compactMap { tab in
            let q = Matcher.quality(query: query, url: tab.url, title: tab.title)
            guard q != .none else { return nil }
            return Suggestion(kind: .openTab, title: tab.title.isEmpty ? URLNormalizer.displayHost(tab.url) : tab.title,
                              subtitle: "Switch to tab",
                              action: .switchToTab(id: tab.id, url: tab.url), score: q.rawValue)
        }
        .prefix(limit).map { $0 }
    }
}

// MARK: - History + bookmarks

/// Implemented by BrowserCore's persistent store. Kept as a protocol so the engine is testable.
public protocol HistoryIndex: Sendable {
    /// Candidates whose host, path or title could match `query`, best frecency first.
    func candidates(matching query: String, limit: Int) async -> [HistoryEntry]
    /// Highest-frecency sites overall, for the zero-state "top sites" row.
    func topSites(limit: Int) async -> [HistoryEntry]
}

public struct HistoryProvider: SuggestionProvider {
    let index: any HistoryIndex

    public init(index: any HistoryIndex) { self.index = index }

    public func suggestions(for query: String, limit: Int) async -> [Suggestion] {
        await index.candidates(matching: query, limit: limit * 3).compactMap { entry in
            let q = Matcher.quality(query: query, url: entry.url, title: entry.title)
            guard q != .none else { return nil }
            return Suggestion(kind: entry.isBookmark ? .bookmark : .history,
                              title: entry.title.isEmpty ? URLNormalizer.displayHost(entry.url) : entry.title,
                              subtitle: URLNormalizer.key(for: entry.url),
                              action: .open(entry.url),
                              score: q.rawValue * Ranker.frecencyFactor(entry.frecency))
        }
    }
}

// MARK: - Bundled seed sites

public struct SeedSite: Codable, Hashable, Sendable {
    /// Domain, e.g. "github.com"
    public let d: String
    /// Display name, e.g. "GitHub"
    public let n: String
    /// Popularity 0...1 (1 = most popular)
    public let w: Double
}

public struct SeedProvider: SuggestionProvider {
    let sites: [SeedSite]

    public init(sites: [SeedSite]) { self.sites = sites }

    /// Loads the seed list bundled with this package.
    public static func bundled() -> SeedProvider {
        guard let url = Bundle.module.url(forResource: "seed-sites", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let sites = try? JSONDecoder().decode([SeedSite].self, from: data)
        else { return SeedProvider(sites: []) }
        return SeedProvider(sites: sites)
    }

    public func suggestions(for query: String, limit: Int) async -> [Suggestion] {
        let q = Matcher.stripForMatching(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        // Seeds only ever match on domain prefix or name prefix: they exist to make
        // "git" -> github.com work on day one, not to do fuzzy search.
        var out: [Suggestion] = []
        for site in sites {
            let nameMatch = site.n.lowercased().hasPrefix(q)
            guard site.d.hasPrefix(q) || nameMatch,
                  let url = URL(string: "https://" + site.d) else { continue }
            let quality: MatchQuality = site.d.hasPrefix(q) ? .hostPrefix : .wordPrefix
            out.append(Suggestion(kind: .seed, title: site.n, subtitle: site.d,
                                  action: .open(url),
                                  score: quality.rawValue * Ranker.seedFactor(site.w)))
            if out.count >= limit * 3 { break }
        }
        return out.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }
}
