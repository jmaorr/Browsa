import Foundation
import Testing
@testable import BrowserCore

@Suite struct LiveFoldersTests {
    func item(_ key: String, _ date: TimeInterval? = nil) -> FetchedItem {
        FetchedItem(key: key, title: key.uppercased(), url: URL(string: "https://example.com/\(key)")!,
                    date: date.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func firstFetchFillsTheFolderNewestFirst() {
        let source = LiveSource(kind: .feed(url: URL(string: "https://example.com/feed")!))
        let plan = LiveFolders.plan(source, fetched: [item("a", 1), item("b", 3), item("c", 2)], inFolder: [])
        #expect(plan.source.items.map(\.key) == ["b", "c", "a"])
        #expect(plan.added.count == 3)
        #expect(plan.source.items.allSatisfy(\.unread))
        #expect(plan.removed.isEmpty)
    }

    @Test func goneItemsLeaveUnlessKept() {
        let source = LiveSource(kind: .github(query: "is:pr"))
        let first = LiveFolders.plan(source, fetched: [item("a"), item("b"), item("c")], inFolder: [])
        let ids = Dictionary(uniqueKeysWithValues: first.source.items.map { ($0.key, $0.tabID) })
        // b merged, c merged but on screen.
        let next = LiveFolders.plan(first.source, fetched: [item("a"), item("d")],
                                    inFolder: Set(ids.values), keep: [ids["c"]!])
        #expect(next.removed == [ids["b"]!])
        #expect(Set(next.source.items.map(\.key)) == ["a", "c", "d"])
        #expect(next.added.map(\.key) == ["d"])
        // a keeps its tab.
        #expect(next.source.items.first { $0.key == "a" }?.tabID == ids["a"])
    }

    @Test func takenOutItemsDontComeBack() {
        let source = LiveSource(kind: .github(query: "is:pr"))
        let first = LiveFolders.plan(source, fetched: [item("a"), item("b")], inFolder: [])
        let a = first.source.items.first { $0.key == "a" }!.tabID
        let b = first.source.items.first { $0.key == "b" }!.tabID
        // a was dragged out of the folder.
        let next = LiveFolders.plan(first.source, fetched: [item("a"), item("b")], inFolder: [b])
        #expect(next.source.items.map(\.key) == ["b"])
        #expect(next.source.dismissed == ["a"])
        #expect(next.added.isEmpty)
        #expect(!next.removed.contains(a))
    }

    @Test func readStaysRead() {
        let source = LiveSource(kind: .github(query: "is:pr"))
        let first = LiveFolders.plan(source, fetched: [item("a")], inFolder: [])
        let a = first.source.items[0].tabID
        let read = LiveFolders.markingRead(a, in: first.source)!
        #expect(read.unreadCount == 0)
        #expect(LiveFolders.markingRead(a, in: read) == nil)
        let next = LiveFolders.plan(read, fetched: [item("a")], inFolder: [a])
        #expect(next.source.items[0].unread == false)
    }

    @Test func limitsHowManyItHolds() {
        let source = LiveSource(kind: .feed(url: URL(string: "https://example.com/feed")!))
        let plan = LiveFolders.plan(source, fetched: (0..<40).map { item("i\($0)") }, inFolder: [], limit: 25)
        #expect(plan.source.items.count == 25)
        #expect(plan.source.items.first?.key == "i0")
    }

    @Test func savesWithTheFolder() throws {
        let live = LiveSource(kind: .feed(url: URL(string: "https://example.com/feed")!),
                              items: [LiveItem(key: "a", tabID: UUID(), title: "A", url: URL(string: "https://example.com/a")!)])
        let layout: [PinnedNode] = [.folder(PinnedFolder(name: "Blog", live: live))]
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode([PinnedNode].self, from: data) == layout)
        // Folders saved before live folders still read.
        let old = #"[{"folder":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Old","isOpen":true,"children":[]}}]"#
        let decoded = try JSONDecoder().decode([PinnedNode].self, from: Data(old.utf8))
        #expect(decoded.first?.folder?.live == nil)
    }

    @Test func readsRSS() throws {
        let rss = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>A Blog</title>
        <item><title>First &amp; best</title><link>https://example.com/1</link><guid>g1</guid>
        <pubDate>Mon, 23 Nov 2026 10:00:00 +0000</pubDate></item>
        <item><title><![CDATA[Second <b>post</b>]]></title><link>/2</link></item>
        </channel></rss>
        """
        let feed = try #require(FeedParser.parse(Data(rss.utf8), base: URL(string: "https://example.com/feed")))
        #expect(feed.title == "A Blog")
        #expect(feed.items.map(\.title) == ["First & best", "Second post"])
        #expect(feed.items[0].key == "g1")
        #expect(feed.items[0].date != nil)
        #expect(feed.items[1].url.absoluteString == "https://example.com/2")
    }

    @Test func readsAtom() throws {
        let atom = """
        <?xml version="1.0" encoding="utf-8"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Channel</title>
        <link href="https://example.com/"/>
        <entry><title>Video</title><id>yt:video:1</id><link rel="alternate" href="https://example.com/watch?v=1"/>
        <published>2026-11-20T08:00:00+00:00</published></entry></feed>
        """
        let feed = try #require(FeedParser.parse(Data(atom.utf8)))
        #expect(feed.title == "Channel")
        #expect(feed.items.count == 1)
        #expect(feed.items[0].url.absoluteString == "https://example.com/watch?v=1")
        #expect(feed.items[0].key == "yt:video:1")
    }

    @Test func htmlIsNotAFeedButLeadsToOne() {
        let html = #"<html><head><link rel="alternate" type="application/rss+xml" title="RSS" href="/feed.xml"><link rel="stylesheet" href="a.css"></head></html>"#
        #expect(FeedParser.parse(Data(html.utf8)) == nil)
        #expect(FeedDiscovery.feedLinks(inHTML: html, base: URL(string: "https://example.com/blog/")!)
                    == [URL(string: "https://example.com/feed.xml")!])
    }

    @Test func readsGitHubSearch() throws {
        let json = #"{"total_count":1,"items":[{"html_url":"https://github.com/o/r/pull/7","title":"Fix it","number":7,"updated_at":"2026-11-23T01:02:03Z","repository_url":"https://api.github.com/repos/o/r"}]}"#
        let items = try GitHubSearch.items(from: Data(json.utf8))
        #expect(items.map(\.title) == ["Fix it · r#7"])
        #expect(items[0].key == "https://github.com/o/r/pull/7")
    }
}
