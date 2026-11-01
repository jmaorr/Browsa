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

    public var all: [Suggestion] { local + (primary.map { [$0] } ?? []) + remote }
}

public final class SuggestEngine: Sendable {
    public struct Config: Sendable {
        public var localLimit = 5
        public var remoteLimit = 4
        public var topSitesLimit = 8
        public var recentTabsLimit = 4
        /// Wait this long after a keystroke before hitting the network.
        public var remoteDebounce: Duration = .milliseconds(60)
        public init() {}
    }

    let local: [any SuggestionProvider]
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
        ]
        self.remote = remoteSuggestionsEnabled ? SearchSuggestProvider(engine: searchEngine) : nil
    }

    /// Test/advanced initialiser with explicit providers.
    public init(localProviders: [any SuggestionProvider], remote: (any SuggestionProvider)?,
                history: any HistoryIndex,
                favorites: @escaping @Sendable () async -> [Favorite],
                openTabs: @escaping @Sendable () async -> [OpenTabSnapshot],
                searchEngine: SearchEngine = .google, config: Config = Config()) {
        self.local = localProviders
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
    public func localResults(for query: String, lastEditWasInsertion: Bool) async -> SuggestResults {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let gathered = await withTaskGroup(of: [Suggestion].self) { group in
            for p in local {
                group.addTask { await p.suggestions(for: trimmed, limit: self.config.localLimit) }
            }
            var all: [Suggestion] = []
            for await batch in group { all += batch }
            return all
        }
        let ranked = Ranker.rankLocal(gathered, limit: config.localLimit)
        return SuggestResults(
            query: query,
            local: ranked,
            primary: primaryRow(for: trimmed),
            remote: [],
            inline: InlineAutocomplete.completion(for: query, lastEditWasInsertion: lastEditWasInsertion, top: ranked),
            isComplete: remote == nil || trimmed.isEmpty
        )
    }

    /// Streams local results immediately, then the same list with remote rows appended.
    /// Cancel the consuming task (or drop the stream) when the user types again.
    public func results(for query: String, lastEditWasInsertion: Bool) -> AsyncStream<SuggestResults> {
        AsyncStream { continuation in
            let task = Task {
                var current = await localResults(for: query, lastEditWasInsertion: lastEditWasInsertion)
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
