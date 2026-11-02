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
    /// Domain, e.g. "github.com" or "docs.google.com"
    public let d: String
    /// Curated display name. When absent, `displayName` derives one from the domain.
    public let n: String?
    /// Popularity 0...1 (1 = most popular), from Chrome UX Report data across ~50 countries.
    public let w: Double
    /// Regions (ISO 3166 alpha-2, lowercase) where this is a local favourite.
    public let r: [String]?
    /// Typed shortcuts that should go straight to this site ("yt", "gh").
    public let a: [String]?

    public init(d: String, n: String? = nil, w: Double, r: [String]? = nil, a: [String]? = nil) {
        self.d = d; self.n = n; self.w = w; self.r = r; self.a = a
    }

    /// "github.com" -> "Github", "bbc.co.uk" -> "BBC", "docs.google.com" -> "Docs Google".
    public var displayName: String {
        if let n { return n }
        let labels = d.split(separator: ".")
        let first = String(labels.first ?? "")
        func pretty(_ l: String) -> String {
            l.count <= 3 ? l.uppercased()
                : l.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        return pretty(first)
    }
}

/// The bundled first-run list: ~7,000 sites people actually visit, so "ne" completes to
/// netflix.com before there is any history. Matching is prefix-only (domain, alias or a word of
/// the name) through a first-character index, so a keystroke touches a few hundred entries.
public struct SeedProvider: SuggestionProvider {
    struct Entry: Sendable {
        let site: SeedSite
        let url: URL
        let nameWords: [String]
        /// Popularity with the regional boost already applied.
        let weight: Double
    }

    let entries: [Entry]
    /// First character of domain / alias / name word -> entry indices (deduplicated, in popularity order).
    let index: [Character: [Int]]

    /// Sites tagged with the user's region get this much extra popularity, so an Australian
    /// typing "ama" lands on amazon.com.au, not amazon.com.
    static let regionalBoost = 0.3

    public init(sites: [SeedSite], region: String? = Locale.current.region?.identifier.lowercased()) {
        var entries: [Entry] = []
        entries.reserveCapacity(sites.count)
        for site in sites {
            guard let url = URL(string: "https://" + site.d) else { continue }
            let words = site.displayName.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let local = region.map { site.r?.contains($0) ?? false } ?? false
            entries.append(Entry(site: site, url: url, nameWords: words,
                                 weight: site.w + (local ? Self.regionalBoost : 0)))
        }
        entries.sort { $0.weight > $1.weight }
        var index: [Character: [Int]] = [:]
        for (i, e) in entries.enumerated() {
            var keys = Set<Character>()
            if let c = e.site.d.first { keys.insert(c) }
            for a in e.site.a ?? [] { if let c = a.first { keys.insert(c) } }
            for w in e.nameWords { if let c = w.first { keys.insert(c) } }
            for k in keys { index[k, default: []].append(i) }
        }
        self.entries = entries
        self.index = index
    }

    /// Loads the seed list bundled with this package.
    public static func bundled(region: String? = Locale.current.region?.identifier.lowercased()) -> SeedProvider {
        guard let url = Bundle.module.url(forResource: "seed-sites", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let sites = try? JSONDecoder().decode([SeedSite].self, from: data)
        else { return SeedProvider(sites: []) }
        return SeedProvider(sites: sites, region: region)
    }

    /// An exact alias ("yt") names a site outright, so Return should open it.
    public func aliasMatch(for query: String) -> Suggestion? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard let c = q.first, !q.contains(" ") else { return nil }
        for i in index[c] ?? [] where entries[i].site.a?.contains(q) == true {
            let e = entries[i]
            return Suggestion(kind: .seed, title: e.site.displayName, subtitle: e.site.d, action: .open(e.url),
                              score: MatchQuality.hostPrefix.rawValue * 1.25 * Ranker.seedFactor(e.weight))
        }
        return nil
    }

    public func suggestions(for query: String, limit: Int) async -> [Suggestion] {
        let q = Matcher.stripForMatching(query.trimmingCharacters(in: .whitespaces))
        guard let c = q.first else { return [] }
        let tokens = q.split(separator: " ").map(String.init)
        var out: [Suggestion] = []
        // Candidates are in popularity order, so we can stop once we have plenty of strong hits.
        for i in index[c] ?? [] {
            let e = entries[i]
            let quality: Double
            if e.site.d.hasPrefix(q) {
                quality = MatchQuality.hostPrefix.rawValue
            } else if e.site.a?.contains(q) == true {
                quality = MatchQuality.hostPrefix.rawValue * 1.25
            } else if tokens.allSatisfy({ t in e.nameWords.contains { $0.hasPrefix(t) } }) {
                quality = MatchQuality.wordPrefix.rawValue
            } else {
                continue
            }
            out.append(Suggestion(kind: .seed, title: e.site.displayName, subtitle: e.site.d,
                                  action: .open(e.url), score: quality * Ranker.seedFactor(e.weight)))
            if out.count >= limit * 4 { break }
        }
        return out.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }
}
