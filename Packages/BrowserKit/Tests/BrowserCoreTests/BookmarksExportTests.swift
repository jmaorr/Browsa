import Testing
import Foundation
@testable import BrowserCore

@Suite struct BookmarksExportTests {
    @Test func foldersNestAndLinksKeepTheirOrder() {
        let html = BookmarksExport.html([
            .folder(name: "Work", children: [
                .link(title: "Mail", url: URL(string: "https://mail.example.com/")!),
                .folder(name: "Docs", children: [.link(title: "Spec", url: URL(string: "https://example.com/spec")!)]),
            ]),
            .link(title: "News", url: URL(string: "https://news.example.com/")!),
        ], title: "Browsa Spaces")
        #expect(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        #expect(html.contains("<TITLE>Browsa Spaces</TITLE>"))
        let work = html.range(of: "<H3>Work</H3>")!, mail = html.range(of: ">Mail</A>")!
        let docs = html.range(of: "<H3>Docs</H3>")!, spec = html.range(of: ">Spec</A>")!, news = html.range(of: ">News</A>")!
        #expect(work.lowerBound < mail.lowerBound && mail.lowerBound < docs.lowerBound)
        #expect(docs.lowerBound < spec.lowerBound && spec.lowerBound < news.lowerBound)
        // Every folder opens and closes its list, plus the outer one.
        #expect(html.components(separatedBy: "<DL><p>").count - 1 == 3)
        #expect(html.components(separatedBy: "</DL><p>").count - 1 == 3)
    }

    @Test func escapesNamesAndAddresses() {
        let html = BookmarksExport.html([
            .folder(name: "R&D <new>", children: [.link(title: "A \"quoted\" page", url: URL(string: "https://example.com/?a=1&b=2")!)]),
        ])
        #expect(html.contains("<H3>R&amp;D &lt;new&gt;</H3>"))
        #expect(html.contains("HREF=\"https://example.com/?a=1&amp;b=2\""))
        #expect(html.contains(">A &quot;quoted&quot; page</A>"))
    }

    @Test func aLinkWithoutATitleShowsItsAddress() {
        let html = BookmarksExport.html([.link(title: "", url: URL(string: "https://example.com/x")!)])
        #expect(html.contains("<A HREF=\"https://example.com/x\">https://example.com/x</A>"))
    }

    @Test func leavesOutAddressesThatArentWebPages() {
        let html = BookmarksExport.html([
            .link(title: "Script", url: URL(string: "javascript:alert(1)")!),
            .link(title: "Data", url: URL(string: "data:text/html,<script>alert(1)</script>")!),
            .link(title: "Extension", url: URL(string: "webkit-extension://abc/popup.html")!),
            .link(title: "Page", url: URL(string: "HTTPS://example.com/")!),
        ])
        #expect(!html.contains("javascript:") && !html.contains("data:") && !html.contains("webkit-extension:"))
        #expect(html.contains(">Page</A>"))
        #expect(html.components(separatedBy: "<A HREF").count - 1 == 1)
    }
}
