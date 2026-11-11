import Foundation

/// Everything the new-tab sheet shows before the user types.
public struct ZeroState: Sendable, Equatable {
    public var favorites: [Favorite]
    public var topSites: [Suggestion]
    public var recentTabs: [OpenTabSnapshot]
}

/// One snapshot of the suggestion list. The UI renders sections in this order:
///   1. `local`   – favourites, open tabs, history, seeds (ranked together)
///   2. `primary` – "Search Google for …" or "Open example.com"
///   3. `remote`  – search-engine suggestions
/// Remote rows only ever append below, so nothing already on screen moves when the network
/// answers. That avoids the "row jumped as I tapped it" bug.
public struct SuggestResults: Sendable, Equatable {
    public let query: String
    public var local: [Suggestion]
    public var primary: Suggestion?
    public var remote: [Suggestion]
    public var inline: InlineCompletion?
    /// False while a remote request is still in flight.
    public var isComplete: Bool
    /// What Return opens when the user hasn't picked a row and there's no inline completion:
    /// an exact alias ("yt" -> youtube.com). nil means "search for the text" (or open it if it's a URL).
    public var defaultAction: SuggestionAction? = nil

    public var all: [Suggestion] { local + (primary.map { [$0] } ?? []) + remote }
}

public final class SuggestEngine: Sendable {
    public struct Config: Sendable {
        public var localLimit = 5
        public var remoteLimit = 5
        public var topSitesLimit = 8
        public var recentTabsLimit = 4
        /// Wait this long after a keystroke before hitting the network.
        public var remoteDebounce: Duration = .milliseconds(60)
        public init() {}
    }

    let local: [any SuggestionProvider]
    let seeds: SeedProvider?
    let remote: (any SuggestionProvider)?
    let history: any HistoryIndex
    let favorites: @Sendable () async -> [Favorite]
    let openTabs: @Sendable () async -> [OpenTabSnapshot]
    let searchEngine: SearchEngine
    let config: Config

    public init(history: any HistoryIndex,
                favorites: @escaping @Sendable () async -> [Favorite],
                openTabs: @escaping @Sendable () async -> [OpenTabSnapshot],
                seeds: SeedProvider = .bundled(),
                searchEngine: SearchEngine = .google,
                remoteSuggestionsEnabled: Bool = true,
                remoteSources: [RemoteSource]? = nil,
                extraProviders: [any SuggestionProvider] = [],
                config: Config = Config()) {
        self.history = history
        self.favorites = favorites
        self.openTabs = openTabs
        self.searchEngine = searchEngine
        self.config = config
        self.local = [
            FavoritesProvider(favorites: favorites),
            OpenTabsProvider(tabs: openTabs),
            HistoryProvider(index: history),
            seeds,
        ] + extraProviders
        self.seeds = seeds
        let sources = remoteSources ?? Self.defaultSources(for: searchEngine)
        self.remote = remoteSuggestionsEnabled && !sources.isEmpty ? RemoteSuggestAggregator(sources: sources) : nil
    }

    /// The chosen engine first, blended with DuckDuckGo when the engine is Google (a second
    /// opinion that improves ordering and covers Google rate-limiting), plus Wikipedia in the
    /// user's language. Choosing DuckDuckGo or Brave never sends keystrokes to Google.
    public static func defaultSources(for engine: SearchEngine,
                                      language: String = Locale.current.language.languageCode?.identifier ?? "en") -> [RemoteSource] {
        var out: [RemoteSource] = [.engine(engine)]
        if engine == .google { out.append(.engine(.duckDuckGo)) }
        out.append(.wikipedia(language: language))
        return out
    }

    /// Test/advanced initialiser with explicit providers.
    public init(localProviders: [any SuggestionProvider], remote: (any SuggestionProvider)?,
                history: any HistoryIndex,
                favorites: @escaping @Sendable () async -> [Favorite],
                openTabs: @escaping @Sendable () async -> [OpenTabSnapshot],
                searchEngine: SearchEngine = .google, config: Config = Config()) {
        self.local = localProviders
        self.seeds = localProviders.lazy.compactMap { $0 as? SeedProvider }.first
        self.remote = remote
        self.history = history
        self.favorites = favorites
        self.openTabs = openTabs
        self.searchEngine = searchEngine
        self.config = config
    }

    // MARK: Zero state

    public func zeroState() async -> ZeroState {
        async let favs = favorites()
        async let top = history.topSites(limit: config.topSitesLimit * 2)
        async let tabs = openTabs()
        let favList = await favs.sorted { $0.order < $1.order }
        let favKeys = Set(favList.map { URLNormalizer.key(for: $0.url) })
        // Don't repeat favourites in the top-sites row.
        let topSites = await top
            .filter { !favKeys.contains(URLNormalizer.key(for: $0.url)) }
            .prefix(config.topSitesLimit)
            .map { Suggestion(kind: .history, title: $0.title.isEmpty ? URLNormalizer.displayHost($0.url) : $0.title,
                              subtitle: URLNormalizer.displayHost($0.url), action: .open($0.url),
                              score: $0.frecency) }
        return ZeroState(favorites: favList, topSites: Array(topSites),
                         recentTabs: Array(await tabs.prefix(config.recentTabsLimit)))
    }

    // MARK: Typing

    /// Local-only pass. Fast enough to call synchronously-ish on every keystroke.
    public func localResults(for query: String, lastEditWasInsertion: Bool, includeRemote: Bool = true) async -> SuggestResults {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let gathered = await withTaskGroup(of: [Suggestion].self) { group in
            for p in local {
                group.addTask { await p.suggestions(for: trimmed, limit: self.config.localLimit) }
            }
            var all: [Suggestion] = []
            for await batch in group { all += batch }
            return all
        }
        var ranked = Ranker.rankLocal(gathered, limit: config.localLimit)
        // An exact alias ("gh") goes to the top unless a favourite or the user's own history
        // already put something stronger there.
        let alias = seeds?.aliasMatch(for: trimmed)
        if let alias, !ranked.contains(where: { $0.dedupeKey == alias.dedupeKey && $0.score >= alias.score }) {
            ranked.removeAll { $0.dedupeKey == alias.dedupeKey }
            let firstIsStronger = ranked.first.map { $0.kind == .favorite || $0.score > alias.score } ?? false
            ranked.insert(alias, at: firstIsStronger ? 1 : 0)
            ranked = Array(ranked.prefix(config.localLimit))
        }
        var results = SuggestResults(
            query: query,
            local: ranked,
            primary: primaryRow(for: trimmed),
            remote: [],
            inline: InlineAutocomplete.completion(for: query, lastEditWasInsertion: lastEditWasInsertion, top: ranked),
            isComplete: !includeRemote || remote == nil || trimmed.isEmpty
        )
        if let alias, ranked.first?.dedupeKey == alias.dedupeKey { results.defaultAction = alias.action }
        // A !bang or a sum leads, and Return does it.
        if let special = Self.specialRow(for: trimmed) {
            results.local.insert(special, at: 0)
            results.local = Array(results.local.prefix(config.localLimit))
            results.defaultAction = special.action
            results.inline = nil
            // A bang already says where the query goes; don't send it to the default engine too.
            if special.dedupeKey.hasPrefix("bang:") { results.isComplete = true }
        }
        return results
    }

    /// "!yt cats" → YouTube's results; "12*7" → 84 (Return copies, through the app's
    /// "copy-text:" command).
    static func specialRow(for trimmed: String) -> Suggestion? {
        if let hit = Bangs.resolve(trimmed) {
            return Suggestion(kind: .searchQuery, title: hit.query.isEmpty ? hit.bang.name : hit.query,
                              subtitle: hit.query.isEmpty ? "Open \(hit.bang.name) · !\(hit.bang.trigger)" : "Search \(hit.bang.name) · !\(hit.bang.trigger)",
                              action: .open(hit.url), score: 1_000, dedupeKey: "bang:" + hit.url.absoluteString)
        }
        if let answer = Calculator.answer(for: trimmed) {
            return Suggestion(kind: .command, title: "= " + answer.text, subtitle: answer.expression + " · Return copies",
                              action: .command(id: "copy-text:" + answer.text), score: 1_000, dedupeKey: "calc:" + answer.text)
        }
        return nil
    }

    /// Streams local results immediately, then the same list with remote rows appended.
    /// Cancel the consuming task (or drop the stream) when the user types again.
    /// With `includeRemote` false, what's typed stays on the device, as in a private tab.
    public func results(for query: String, lastEditWasInsertion: Bool, includeRemote: Bool = true) -> AsyncStream<SuggestResults> {
        AsyncStream { continuation in
            let task = Task {
                var current = await localResults(for: query, lastEditWasInsertion: lastEditWasInsertion, includeRemote: includeRemote)
                continuation.yield(current)
                guard !current.isComplete, let remote else { continuation.finish(); return }

                try? await Task.sleep(for: config.remoteDebounce)
                guard !Task.isCancelled else { continuation.finish(); return }

                let shownKeys = Set(current.local.map(\.dedupeKey) + [current.primary?.dedupeKey].compactMap { $0 })
                current.remote = await remote.suggestions(for: query, limit: config.remoteLimit)
                    .filter { !shownKeys.contains($0.dedupeKey) }
                current.isComplete = true
                guard !Task.isCancelled else { continuation.finish(); return }
                continuation.yield(current)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func primaryRow(for trimmed: String) -> Suggestion? {
        guard !trimmed.isEmpty else { return nil }
        if let url = URLNormalizer.urlIfNavigable(trimmed) {
            return Suggestion(kind: .searchQuery, title: URLNormalizer.key(for: url),
                              subtitle: "Open", action: .open(url), score: 0)
        }
        return Suggestion(kind: .searchQuery, title: trimmed,
                          subtitle: "Search \(searchEngine.name)", action: .search(trimmed), score: 0)
    }
}
