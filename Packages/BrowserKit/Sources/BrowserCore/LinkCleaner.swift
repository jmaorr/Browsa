import Foundation

/// Strips click-tracking parameters (utm_*, fbclid, gclid…) from links before they load, and
/// from links you copy or share. Only parameters whose sole job is tracking are removed, so
/// pages still get everything they need.
public enum LinkCleaner {
    /// Removed on every site.
    static let global: Set<String> = [
        // Ad click IDs
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "ttclid",
        "twclid", "li_fat_id", "epik", "srsltid",
        // Email and marketing platforms
        "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
        "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "vero_conv", "_kx", "ck_subscriber_id",
        "rb_clickid", "s_cid", "wickedid", "ml_subscriber", "ml_subscriber_hash",
        // Social share tags
        "igshid", "igsh",
    ]
    /// Removed when the name starts with one of these.
    static let prefixes = ["utm_", "pk_", "mtm_"]
    /// Removed only on these sites, where the name is generic elsewhere.
    static let perSite: [String: Set<String>] = [
        "youtube.com": ["si", "pp", "feature"],
        "youtu.be": ["si", "feature"],
        "open.spotify.com": ["si", "context"],
        "twitter.com": ["s", "t", "ref_src", "ref_url"],
        "x.com": ["s", "t", "ref_src", "ref_url"],
        "instagram.com": ["igsh", "img_index"],
        "tiktok.com": ["_r", "_t", "is_from_webapp", "sender_device", "sender_web_id"],
        "amazon.com": ["ref_", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "pf_rd_r", "pf_rd_p", "pd_rd_i", "content-id"],
        "reddit.com": ["share_id", "rdt", "ref_campaign", "ref_source"],
        "linkedin.com": ["trk", "trkInfo", "lipi", "trackingId", "refId"],
    ]

    /// The URL without tracking parameters, or nil when there was nothing to remove.
    public static func clean(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = parts.queryItems, !items.isEmpty else { return nil }
        let host = (parts.host ?? "").lowercased()
        let siteParams = perSite.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value ?? []
        let kept = items.filter { item in
            let name = item.name.lowercased()
            if global.contains(name) || siteParams.contains(item.name) || siteParams.contains(name) { return false }
            return !prefixes.contains { name.hasPrefix($0) }
        }
        guard kept.count != items.count else { return nil }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.url
    }

    /// `clean(url)` if anything was removed, otherwise the URL itself.
    public static func cleaned(_ url: URL) -> URL { clean(url) ?? url }
}
