import Foundation
import Testing
@testable import Suggest

@Suite struct SeedTests {
    let sites = [
        SeedSite(d: "amazon.com", n: "Amazon", w: 1.0, a: ["amzn"]),
        SeedSite(d: "amazon.com.au", n: "Amazon Australia", w: 0.76, r: ["au", "nz"]),
        SeedSite(d: "youtube.com", n: "YouTube", w: 1.0, a: ["yt"]),
        SeedSite(d: "nytimes.com", n: "The New York Times", w: 0.9, a: ["nyt"]),
        SeedSite(d: "bbc.co.uk", w: 0.8),
    ]

    @Test func regionalSiteWinsInItsRegion() async {
        let au = await SeedProvider(sites: sites, region: "au").suggestions(for: "ama", limit: 3)
        #expect(au.first?.subtitle == "amazon.com.au")
        let us = await SeedProvider(sites: sites, region: "us").suggestions(for: "ama", limit: 3)
        #expect(us.first?.subtitle == "amazon.com")
    }

    @Test func aliasAndNameWordsMatch() async {
        let p = SeedProvider(sites: sites, region: nil)
        #expect(await p.suggestions(for: "yt", limit: 3).first?.subtitle == "youtube.com")
        #expect(await p.suggestions(for: "new york", limit: 3).first?.subtitle == "nytimes.com")
        #expect(p.aliasMatch(for: "nyt")?.subtitle == "nytimes.com")
        #expect(p.aliasMatch(for: "ny") == nil)
    }

    @Test func derivedNames() {
        #expect(SeedSite(d: "bbc.co.uk", w: 1).displayName == "BBC")
        #expect(SeedSite(d: "ultimate-guitar.com", w: 1).displayName == "Ultimate Guitar")
    }

    @Test func aliasBecomesReturnDefault() async {
        let index = InMemoryHistoryIndex([])
        let e = SuggestEngine(localProviders: [SeedProvider(sites: sites, region: nil)], remote: nil, history: index,
                              favorites: { [] }, openTabs: { [] })
        let r = await e.localResults(for: "yt", lastEditWasInsertion: true)
        #expect(r.defaultAction == .open(URL(string: "https://youtube.com")!))
    }

    @Test func aliasTopRowSuppressesInlineCompletionFromLowerRows() async {
        let index = InMemoryHistoryIndex([])
        let list = [SeedSite(d: "github.com", n: "GitHub", w: 1.0, a: ["gh"]), SeedSite(d: "ghanaweb.com", w: 0.5)]
        let e = SuggestEngine(localProviders: [SeedProvider(sites: list, region: nil)], remote: nil, history: index,
                              favorites: { [] }, openTabs: { [] })
        let r = await e.localResults(for: "gh", lastEditWasInsertion: true)
        #expect(r.local.first?.subtitle == "github.com")
        #expect(r.inline == nil)
        #expect(r.defaultAction == .open(URL(string: "https://github.com")!))
    }

    @Test func bundledListIsLargeCleanAndStartsWithTheBigNames() async throws {
        let url = try #require(Bundle.module.url(forResource: "seed-sites", withExtension: "json"))
        let list = try JSONDecoder().decode([SeedSite].self, from: Data(contentsOf: url))
        #expect(list.count > 5000)
        let top = Set(list.prefix(60).map(\.d))
        for d in ["google.com", "youtube.com", "facebook.com", "wikipedia.org", "github.com"] {
            #expect(top.contains(d), "\(d) should be near the top")
        }
        let banned = try Regex("porn|xxx|xvideo|casino|torrent|movierulz|y2mate")
        #expect(!list.contains { $0.d.contains(banned) })
        let p = SeedProvider(sites: list, region: "au")
        #expect(await p.suggestions(for: "you", limit: 1).first?.subtitle == "youtube.com")
        #expect(await p.suggestions(for: "gh", limit: 1).first?.subtitle == "github.com")
    }
}

@Suite struct RemoteMergeTests {
    let google = RemoteSource.engine(.google)
    let ddg = RemoteSource.engine(.duckDuckGo)
    let wiki = RemoteSource.wikipedia(language: "en")

    func q(_ t: String) -> RemoteHit { RemoteHit(text: t, url: nil, relevance: nil) }

    @Test func agreementLiftsARow() {
        let merged = RemoteSuggestAggregator.merge([
            (google, [q("swift ui"), q("swift taylor"), q("swift code")]),
            (ddg, [q("swift code"), q("swift bank")]),
        ], query: "swift", limit: 5)
        #expect(merged.first?.title == "swift code")
        #expect(merged.map(\.title).contains("swift bank"))
        #expect(merged.count == 4)
    }

    @Test func siteLinkGoesFirstAndArticleLast() {
        let merged = RemoteSuggestAggregator.merge([
            (google, [q("github copilot"), RemoteHit(text: "github.com", url: URL(string: "https://github.com/")!, relevance: nil)]),
            (wiki, [RemoteHit(text: "GitHub", url: URL(string: "https://en.wikipedia.org/wiki/GitHub")!, relevance: nil)]),
        ], query: "github", limit: 5)
        #expect(merged.first?.kind == .remoteSite)
        #expect(merged.last?.kind == .entity)
    }

    @Test func articleNeedsATitlePrefixMatch() {
        let merged = RemoteSuggestAggregator.merge([
            (wiki, [RemoteHit(text: "Taylor Swift", url: URL(string: "https://en.wikipedia.org/wiki/Taylor_Swift")!, relevance: nil)]),
        ], query: "swift", limit: 5)
        #expect(merged.isEmpty)
    }

    @Test func googleChromeClientParsesNavigationRows() throws {
        let body = #"["git",["github","https://github.com/","gitlab"],["","",""],[],{"google:suggesttype":["QUERY","NAVIGATION","QUERY"],"google:suggestrelevance":[1250,900,600]}]"#
        let hits = SearchEngine.google.parseHits(Data(body.utf8))
        #expect(hits.count == 3)
        #expect(hits[1].url?.host() == "github.com")
        #expect(hits[0].relevance == 1250)
        #expect(SearchEngine.google.parseSuggestions(Data(body.utf8)) == ["github", "gitlab"])
    }

    @Test func defaultSourcesRespectPrivacyChoice() {
        #expect(SuggestEngine.defaultSources(for: .duckDuckGo, language: "en") == [.engine(.duckDuckGo), .wikipedia(language: "en")])
        #expect(SuggestEngine.defaultSources(for: .google, language: "en").count == 3)
    }
}
