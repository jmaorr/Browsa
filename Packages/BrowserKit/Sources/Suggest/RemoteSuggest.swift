import Foundation

/// One place remote suggestions come from.
public enum RemoteSource: Hashable, Sendable {
    /// Query completions (and, for Google, site links) from a search engine.
    case engine(SearchEngine)
    /// The top Wikipedia article whose title starts with the query, for "who/what is" lookups.
    case wikipedia(language: String)

    var name: String { displayName }

    public var displayName: String {
        switch self {
        case .engine(let e): e.name
        case .wikipedia: "Wikipedia"
        }
    }

    /// How much this source's opinion counts when lists are merged.
    var weight: Double {
        switch self {
        case .engine: 1.0
        case .wikipedia: 0.6
        }
    }

    func request(for query: String) -> URLRequest {
        switch self {
        case .engine(let e):
            return e.suggestRequest(for: query)
        case .wikipedia(let lang):
            var c = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")!
            c.queryItems = [.init(name: "action", value: "opensearch"), .init(name: "search", value: query),
                            .init(name: "limit", value: "3"), .init(name: "namespace", value: "0"),
                            .init(name: "format", value: "json")]
            var req = URLRequest(url: c.url!, timeoutInterval: 2)
            req.setValue("DuoBrowser/1.0 (iOS; suggestions)", forHTTPHeaderField: "User-Agent")
            return req
        }
    }

    func parse(_ data: Data) -> [RemoteHit] {
        switch self {
        case .engine(let e):
            return e.parseHits(data)
        case .wikipedia:
            // ["query", [titles], [descriptions], [urls]]
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [Any], arr.count >= 4,
                  let titles = arr[1] as? [String], let urls = arr[3] as? [String] else { return [] }
            return zip(titles, urls).compactMap { t, u in
                URL(string: u).map { RemoteHit(text: t, url: $0, relevance: nil) }
            }
        }
    }
}

/// Small LRU so Backspace, retyping and the second keystroke of a pair are instant.
actor RemoteSuggestCache {
    private var store: [String: (hits: [RemoteHit], at: Date)] = [:]
    private var order: [String] = []
    private let capacity: Int
    private let ttl: TimeInterval

    init(capacity: Int = 128, ttl: TimeInterval = 10 * 60) {
        self.capacity = capacity
        self.ttl = ttl
    }

    func get(_ key: String) -> [RemoteHit]? {
        guard let e = store[key], Date().timeIntervalSince(e.at) < ttl else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return e.hits
    }

    func set(_ key: String, _ hits: [RemoteHit]) {
        store[key] = (hits, Date())
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity { store[order.removeFirst()] = nil }
    }
}

/// Asks several services at once and blends their answers:
///
/// - Every source runs in parallel with its own timeout, and the whole batch has a deadline, so
///   one slow service never holds up the list. Whatever has arrived by then is used.
/// - Query completions are merged by normalised text. Each source scores its rows by position
///   (or the engine's own relevance), scaled by the source's weight, and rows that several
///   sources agree on add up and rise. Ties keep the primary engine's order.
/// - Site links (Google NAVIGATION rows) and one Wikipedia article ride along as tappable sites.
/// - Answers are cached per source and query.
public struct RemoteSuggestAggregator: SuggestionProvider {
    public let sources: [RemoteSource]
    let session: URLSession
    let cache = RemoteSuggestCache()
    /// Give up on stragglers after this long.
    let deadline: Duration

    public var isRemote: Bool { true }

    public init(sources: [RemoteSource], session: URLSession = .shared, deadline: Duration = .milliseconds(900)) {
        self.sources = sources
        self.session = session
        self.deadline = deadline
    }

    public func suggestions(for query: String, limit: Int) async -> [Suggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let answers = await fetchAll(trimmed)
        return Self.merge(answers, query: trimmed, limit: limit)
    }

    func fetchAll(_ query: String) async -> [(RemoteSource, [RemoteHit])] {
        let active = sources.filter { source in
            // Wikipedia only once there's enough to mean something.
            if case .wikipedia = source { return query.count >= 3 }
            return true
        }
        return await withTaskGroup(of: (RemoteSource, [RemoteHit])?.self) { group in
            for source in active {
                group.addTask { await (source, self.fetch(source, query)) }
            }
            group.addTask {
                try? await Task.sleep(for: self.deadline)
                return nil   // deadline marker
            }
            var out: [(RemoteSource, [RemoteHit])] = []
            for await result in group {
                guard let result else { break }   // deadline hit: use what we have
                out.append(result)
                if out.count == active.count { break }
            }
            group.cancelAll()
            // Keep the configured source order so the primary engine wins ties.
            return out.sorted { a, b in
                (active.firstIndex(of: a.0) ?? 0) < (active.firstIndex(of: b.0) ?? 0)
            }
        }
    }

    private func fetch(_ source: RemoteSource, _ query: String) async -> [RemoteHit] {
        let key = "\(source.name)|\(query.lowercased())"
        if let hit = await cache.get(key) { return hit }
        guard let (data, response) = try? await session.data(for: source.request(for: query)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let hits = source.parse(data)
        await cache.set(key, hits)
        return hits
    }

    // MARK: Merge (pure, unit-tested)

    static func merge(_ answers: [(RemoteSource, [RemoteHit])], query: String, limit: Int) -> [Suggestion] {
        let q = query.lowercased()
        var queryScores: [String: (text: String, score: Double, firstSeen: Int)] = [:]
        var sites: [Suggestion] = []
        var seen = 0

        for (source, hits) in answers {
            let maxRel = hits.compactMap(\.relevance).max() ?? 0
            for (rank, hit) in hits.enumerated() {
                // Position score 1.0, 0.92, 0.84... or the engine's relevance when it gives one.
                let positional = max(0.2, 1.0 - Double(rank) * 0.08)
                let relevance = (hit.relevance.map { maxRel > 0 ? $0 / maxRel : positional }) ?? positional
                let score = source.weight * relevance

                if let url = hit.url {
                    switch source {
                    case .wikipedia:
                        // Only the best article, and only if its title really starts with the query.
                        guard rank == 0, hit.text.lowercased().hasPrefix(q) else { continue }
                        sites.append(Suggestion(kind: .entity, title: hit.text, subtitle: "Wikipedia",
                                                action: .open(url), score: score * 0.5))
                    case .engine:
                        sites.append(Suggestion(kind: .remoteSite, title: hit.text,
                                                subtitle: URLNormalizer.key(for: url), action: .open(url),
                                                score: score + 0.5))
                    }
                    continue
                }

                let norm = hit.text.lowercased().trimmingCharacters(in: .whitespaces)
                guard !norm.isEmpty, norm != q else { continue }
                if var existing = queryScores[norm] {
                    existing.score += score
                    queryScores[norm] = existing
                } else {
                    queryScores[norm] = (hit.text, score, seen)
                    seen += 1
                }
            }
        }

        let queries = queryScores.values
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.firstSeen < $1.firstSeen }
            .map { Suggestion(kind: .searchSuggestion, title: $0.text, action: .search($0.text), score: $0.score) }

        // At most one engine site link and one article, so query completions stay the bulk.
        let siteLink = sites.filter { $0.kind == .remoteSite }.max { $0.score < $1.score }
        let article = sites.first { $0.kind == .entity }
        var out = Array(queries.prefix(max(0, limit - (siteLink == nil ? 0 : 1) - (article == nil ? 0 : 1))))
        if let siteLink { out.insert(siteLink, at: 0) }
        if let article { out.append(article) }
        return out
    }
}
