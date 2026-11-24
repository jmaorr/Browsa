import Testing
import Foundation
@testable import BrowserCore

@Suite struct YouTubeAdRulesTests {
    @Test func appendedListIsValidJSON() throws {
        let out = YouTubeAdRules.appending(to: #"[{"trigger":{"url-filter":"ads\\.example"},"action":{"type":"block"}}]"#)
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]])
        #expect(rules.count == 1 + YouTubeAdRules.json.count)
    }

    @Test func filtersAreRegexesThatMatchYouTubeAdPaths() throws {
        let out = YouTubeAdRules.appending(to: "[]")
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]])
        let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        func matches(_ url: String) -> Bool { filters.contains { url.range(of: $0, options: .regularExpression) != nil } }
        #expect(matches("https://www.youtube.com/api/stats/ads?ver=2"))
        #expect(matches("https://www.youtube.com/youtubei/v1/player/ad_break?key=1"))
        #expect(!matches("https://www.youtube.com/youtubei/v1/player?key=1"))
        #expect(!matches("https://rr3---sn.googlevideo.com/videoplayback?id=1"))
    }
}
