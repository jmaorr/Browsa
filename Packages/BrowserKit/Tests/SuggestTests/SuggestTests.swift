import Foundation
import Testing
@testable import Suggest

private func url(_ s: String) -> URL { URL(string: s)! }

private func engine(history: [HistoryEntry] = [],
                    favorites: [Favorite] = [],
                    tabs: [OpenTabSnapshot] = [],
                    seeds: [SeedSite] = []) -> SuggestEngine {
    let index = InMemoryHistoryIndex(history)
    let favs = favorites, openTabs = tabs
    return SuggestEngine(
        localProviders: [
            FavoritesProvider(favorites: { favs }),
            OpenTabsProvider(tabs: { openTabs }),
            HistoryProvider(index: index),
            SeedProvider(sites: seeds),
        ],
        remote: nil, history: index,
        favorites: { favs }, openTabs: { openTabs })
}

@Suite struct MatcherTests {
    @Test func hostPrefixIgnoresSchemeAndWWW() {
        #expect(Matcher.quality(query: "git", url: url("https://www.github.com/"), title: "GitHub") == .hostPrefix)
        #expect(Matcher.quality(query: "https://git", url: url("https://github.com"), title: "") == .hostPrefix)
    }

    @Test func wordPrefixMatchesTitleWords() {
        #expect(Matcher.quality(query: "swift forum", url: url("https://forums.swift.org"), title: "Swift Forums") == .wordPrefix)
    }

    @Test func noMatch() {
        #expect(Matcher.quality(query: "zzz", url: url("https://github.com"), title: "GitHub") == .none)
    }
}

@Suite struct URLNormalizerTests {
    @Test func navigableInputs() {
        #expect(URLNormalizer.urlIfNavigable("github.com")?.absoluteString == "https://github.com")
        #expect(URLNormalizer.urlIfNavigable("localhost:3000")?.absoluteString == "https://localhost:3000")
        #expect(URLNormalizer.urlIfNavigable("http://example.com/a")?.absoluteString == "http://example.com/a")
    }

    @Test func searchInputs() {
        #expect(URLNormalizer.urlIfNavigable("best pizza near me") == nil)
        #expect(URLNormalizer.urlIfNavigable("swiftui") == nil)
        #expect(URLNormalizer.urlIfNavigable("end.") == nil)
    }
}

@Suite struct RankingTests {
    @Test func favouriteBeatsHistoryAndSeed() async {
        let e = engine(
            history: [HistoryEntry(url: url("https://gitlab.com"), title: "GitLab", frecency: 20)],
            favorites: [Favorite(url: url("https://github.com"), title: "GitHub", order: 0)],
            seeds: [SeedSite(d: "git-scm.com", n: "Git", w: 0.9)])
        let r = await e.localResults(for: "git", lastEditWasInsertion: true)
        #expect(r.local.first?.kind == .favorite)
        #expect(r.local.first?.url?.host() == "github.com")
    }

    @Test func historyOvertakesSeedAfterAFewVisits() async {
        let f = Frecency()
        let now = Date()
        var score = 0.0
        for _ in 0..<2 { score = f.adding(.typed, to: score, lastUpdate: now, now: now) }
        let e = engine(
            history: [HistoryEntry(url: url("https://news.example.com"), title: "Example News", frecency: score)],
            seeds: [SeedSite(d: "news.ycombinator.com", n: "Hacker News", w: 1.0)])
        let r = await e.localResults(for: "news", lastEditWasInsertion: true)
        #expect(r.local.first?.kind == .history)
    }

    @Test func duplicatesMergeKeepingBestKind() async {
        let e = engine(
            history: [HistoryEntry(url: url("https://github.com/"), title: "GitHub", frecency: 5)],
            favorites: [Favorite(url: url("https://www.github.com"), title: "GitHub", order: 0)],
            seeds: [SeedSite(d: "github.com", n: "GitHub", w: 1)])
        let r = await e.localResults(for: "git", lastEditWasInsertion: true)
        #expect(r.local.count == 1)
        #expect(r.local.first?.kind == .favorite)
    }

    @Test func primaryRowIsSearchOrOpen() async {
        let e = engine()
        let search = await e.localResults(for: "swift testing", lastEditWasInsertion: true)
        #expect(search.primary?.action == .search("swift testing"))
        let open = await e.localResults(for: "example.com", lastEditWasInsertion: true)
        #expect(open.primary?.action == .open(url("https://example.com")))
    }
}

@Suite struct InlineAutocompleteTests {
    let top = [Suggestion(kind: .history, title: "GitHub", action: .open(URL(string: "https://github.com/apple/swift?tab=readme")!), score: 1)]

    @Test func completesHost() {
        let c = InlineAutocomplete.completion(for: "Git", lastEditWasInsertion: true, top: top)
        #expect(c?.typed == "Git")
        #expect(c?.completion == "hub.com")
        #expect(c?.fullText == "Github.com")
    }

    @Test func completesFirstPathSegmentButNeverQuery() {
        let c = InlineAutocomplete.completion(for: "github.com/a", lastEditWasInsertion: true, top: top)
        #expect(c?.completion == "pple")
        #expect(c?.url.absoluteString == "https://github.com/apple")
    }

    @Test func noCompletionAfterBackspaceOrSpace() {
        #expect(InlineAutocomplete.completion(for: "git", lastEditWasInsertion: false, top: top) == nil)
        #expect(InlineAutocomplete.completion(for: "git hub", lastEditWasInsertion: true, top: top) == nil)
    }
}

@Suite struct ZeroStateTests {
    @Test func favouritesSortedAndNotRepeatedInTopSites() async {
        let e = engine(
            history: [
                HistoryEntry(url: url("https://github.com"), title: "GitHub", frecency: 50),
                HistoryEntry(url: url("https://news.ycombinator.com"), title: "HN", frecency: 30),
            ],
            favorites: [
                Favorite(url: url("https://github.com"), title: "GitHub", order: 1),
                Favorite(url: url("https://claude.ai"), title: "Claude", order: 0),
            ])
        let z = await e.zeroState()
        #expect(z.favorites.map(\.title) == ["Claude", "GitHub"])
        #expect(z.topSites.map { $0.url?.host() } == ["news.ycombinator.com"])
    }
}

@Suite struct SearchEngineParsingTests {
    @Test func googleShape() {
        let data = #"["swi",["swift","swiftui","swimming"]]"#.data(using: .utf8)!
        #expect(SearchEngine.google.parseSuggestions(data) == ["swift", "swiftui", "swimming"])
    }

    @Test func braveShape() {
        let data = #"{"type":"suggest","query":{"original":"swi"},"results":[{"query":"swift"},{"query":"swiftui"}]}"#.data(using: .utf8)!
        #expect(SearchEngine.brave(apiKey: "x").parseSuggestions(data) == ["swift", "swiftui"])
    }
}
