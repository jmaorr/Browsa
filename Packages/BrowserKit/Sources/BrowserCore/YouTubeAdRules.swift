import Foundation

/// Extra content-blocker rules for YouTube, appended to the Ads group. Where YouTube's player reports ads
/// and fetches them, never the video. Adapted from Search (github.com/driceroland/Search, MIT,
/// © 2026 Office Commun); see WebKitEngine/YouTubeAds.swift for the full notice and the page scripts.
enum YouTubeAdRules {
    /// Bump when the rules change, so compiled lists are rebuilt.
    static let version = "1"

    static let paths = [
        "/api/stats/ads", "/pagead/", "/ptracking", "/get_midroll_info",
        "/youtubei/v1/player/ad_break", "/pcs/activeview",
    ]

    private static func youtube(_ path: String) -> String {
        "^https?://([^/]+\\\\.)?youtube\\\\.com" + path.replacingOccurrences(of: ".", with: "\\\\.")
    }

    /// The rules as JSON objects, ready to splice into a rule list.
    static var json: [String] {
        let onYouTube = #""if-domain":["*youtube.com","*youtube-nocookie.com"]"#
        var rules = paths.map { #"{"trigger":{"url-filter":"\#(youtube($0))"},"action":{"type":"block"}}"# }
        // The player's quality reports for an ad, never the video's own.
        rules.append(#"{"trigger":{"url-filter":"^https?://([^/]+\\.)?youtube\\.com/api/stats/qoe\\?.*adformat="},"action":{"type":"block"}}"#)
        // Google's ad paths and the video ads SDK, only on YouTube: other players may need the SDK to play.
        rules.append(#"{"trigger":{"url-filter":"^https?://([^/]+\\.)?google\\.com/pagead/",\#(onYouTube)},"action":{"type":"block"}}"#)
        rules.append(#"{"trigger":{"url-filter":"^https?://imasdk\\.googleapis\\.com/",\#(onYouTube)},"action":{"type":"block"}}"#)
        // YouTube's blocker test, a one-line script setting google_ad_status: let through on YouTube only,
        // so accounts YouTube enforces on don't get the "ad blockers violate" wall.
        rules.append(#"{"trigger":{"url-filter":"^https?://static\\.doubleclick\\.net/instream/ad_status\\.js",\#(onYouTube)},"action":{"type":"ignore-previous-rules"}}"#)
        return rules
    }

    /// `json` with the YouTube rules added at the end.
    static func appending(to json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("]") else { return json }
        let body = trimmed.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = Self.json.joined(separator: ",")
        return body == "[" ? "[\(extra)]" : "\(body),\(extra)]"
    }
}
