import Testing
import Foundation
@testable import BrowserCore

@Suite struct LinkCleanerTests {
    @Test func stripsMarketingParameters() {
        let url = URL(string: "https://example.com/a?id=7&utm_source=x&utm_medium=email&fbclid=abc")!
        #expect(LinkCleaner.clean(url)?.absoluteString == "https://example.com/a?id=7")
    }

    @Test func dropsTheQuestionMarkWhenNothingIsLeft() {
        let url = URL(string: "https://example.com/a?gclid=1#top")!
        #expect(LinkCleaner.clean(url)?.absoluteString == "https://example.com/a#top")
    }

    @Test func leavesCleanLinksAlone() {
        #expect(LinkCleaner.clean(URL(string: "https://example.com/search?q=utm")!) == nil)
        #expect(LinkCleaner.clean(URL(string: "https://example.com/")!) == nil)
    }

    @Test func siteSpecificParametersOnlyOnThatSite() {
        let yt = URL(string: "https://www.youtube.com/watch?v=abc&si=XYZ")!
        #expect(LinkCleaner.clean(yt)?.absoluteString == "https://www.youtube.com/watch?v=abc")
        // "si" means something else elsewhere.
        #expect(LinkCleaner.clean(URL(string: "https://example.com/?si=1")!) == nil)
    }

    @Test func ignoresNonWebSchemes() {
        #expect(LinkCleaner.clean(URL(string: "mailto:a@b.com?utm_source=x")!) == nil)
    }
}

@Suite struct BlockingAllowlistTests {
    @Test func coversSubdomains() {
        var s = BrowserSettings()
        s.blockingDisabledHosts = ["example.com"]
        #expect(s.blockingDisabled(for: "example.com"))
        #expect(s.blockingDisabled(for: "news.example.com"))
        #expect(!s.blockingDisabled(for: "notexample.com"))
        #expect(!s.blockingDisabled(for: nil))
    }
}
