import Foundation

/// DuckDuckGo-style !bangs, resolved on the Mac: "!yt lo-fi" or "lo-fi !yt" goes straight to
/// YouTube's results, and nothing about it is sent to the default search engine first.
/// A bang on its own ("!gh") opens the site.
public enum Bangs {
    public struct Bang: Sendable, Hashable {
        public let trigger: String
        public let name: String
        /// "{q}" is replaced by the encoded query.
        public let template: String
        public let home: String
        /// Other names for it: "youtube" as well as "yt".
        public var aliases: [String] = []
        /// Not one of ours: DuckDuckGo resolves it.
        public var isFallback = false
    }

    /// Popular bangs, with the other names DuckDuckGo knows them by ("!yt" and "!youtube").
    /// Any other "!word" still works: it goes to DuckDuckGo, which knows about 13,000.
    public static let all: [Bang] = [
        b(["g", "google"], "Google", "https://www.google.com/search?q={q}"),
        b(["ddg", "duckduckgo", "duck"], "DuckDuckGo", "https://duckduckgo.com/?q={q}"),
        b(["b", "bing"], "Bing", "https://www.bing.com/search?q={q}"),
        b(["brave", "bs"], "Brave Search", "https://search.brave.com/search?q={q}"),
        b(["k", "kagi"], "Kagi", "https://kagi.com/search?q={q}"),
        b(["eco", "ecosia"], "Ecosia", "https://www.ecosia.org/search?q={q}"),
        b(["yt", "youtube"], "YouTube", "https://www.youtube.com/results?search_query={q}"),
        b(["w", "wiki", "wikipedia", "wen"], "Wikipedia", "https://en.wikipedia.org/w/index.php?search={q}"),
        b(["gh", "github"], "GitHub", "https://github.com/search?q={q}&type=repositories"),
        b(["ghc", "ghcode"], "GitHub Code", "https://github.com/search?q={q}&type=code"),
        b(["so", "stackoverflow"], "Stack Overflow", "https://stackoverflow.com/search?q={q}"),
        b(["mdn"], "MDN", "https://developer.mozilla.org/en-US/search?q={q}"),
        b(["npm"], "npm", "https://www.npmjs.com/search?q={q}"),
        b(["pypi", "pip"], "PyPI", "https://pypi.org/search/?q={q}"),
        b(["crates", "cargo"], "crates.io", "https://crates.io/search?q={q}"),
        b(["spi"], "Swift Package Index", "https://swiftpackageindex.com/search?query={q}"),
        b(["ad", "apple", "appledev"], "Apple Developer", "https://developer.apple.com/search/?q={q}"),
        b(["caniuse", "ciu"], "Can I use", "https://caniuse.com/?search={q}"),
        b(["hn", "hackernews"], "Hacker News", "https://hn.algolia.com/?q={q}"),
        b(["r", "reddit"], "Reddit", "https://www.reddit.com/search/?q={q}"),
        b(["x", "twitter", "tw"], "X", "https://x.com/search?q={q}"),
        b(["bsky", "bluesky"], "Bluesky", "https://bsky.app/search?q={q}"),
        b(["li", "linkedin"], "LinkedIn", "https://www.linkedin.com/search/results/all/?keywords={q}"),
        b(["a", "amazon", "amz"], "Amazon", "https://www.amazon.com/s?k={q}"),
        b(["ebay"], "eBay", "https://www.ebay.com/sch/i.html?_nkw={q}"),
        b(["amaps", "applemaps"], "Apple Maps", "https://maps.apple.com/?q={q}"),
        b(["m", "maps", "gm", "gmaps", "googlemaps"], "Google Maps", "https://www.google.com/maps/search/{q}"),
        b(["osm", "openstreetmap"], "OpenStreetMap", "https://www.openstreetmap.org/search?query={q}"),
        b(["imdb"], "IMDb", "https://www.imdb.com/find/?q={q}"),
        b(["lb", "letterboxd"], "Letterboxd", "https://letterboxd.com/search/{q}/"),
        b(["i", "gi", "img", "images"], "Google Images", "https://www.google.com/search?tbm=isch&q={q}"),
        b(["n", "news", "gnews"], "Google News", "https://news.google.com/search?q={q}"),
        b(["un", "unsplash"], "Unsplash", "https://unsplash.com/s/photos/{q}"),
        b(["gt", "translate"], "Google Translate", "https://translate.google.com/?sl=auto&tl=en&text={q}"),
        b(["deepl"], "DeepL", "https://www.deepl.com/translator#auto/en/{q}"),
        b(["wa", "wolfram", "wolframalpha"], "Wolfram|Alpha", "https://www.wolframalpha.com/input?i={q}"),
        b(["ud", "urban"], "Urban Dictionary", "https://www.urbandictionary.com/define.php?term={q}"),
        b(["d", "define", "dict"], "Dictionary", "https://www.merriam-webster.com/dictionary/{q}"),
        b(["wb", "wayback", "archive"], "Wayback Machine", "https://web.archive.org/web/*/{q}"),
        b(["arxiv"], "arXiv", "https://arxiv.org/search/?query={q}&searchtype=all"),
        b(["scholar", "gs"], "Google Scholar", "https://scholar.google.com/scholar?q={q}"),
        b(["figma"], "Figma Community", "https://www.figma.com/community/search?query={q}"),
        b(["dribbble"], "Dribbble", "https://dribbble.com/search/{q}"),
        b(["sf", "sfsymbols"], "SF Symbols (Hotpot)", "https://hotpot.ai/free-icons?s=sfSymbols&q={q}"),
        b(["spotify", "sp"], "Spotify", "https://open.spotify.com/search/{q}"),
        b(["music", "applemusic"], "Apple Music", "https://music.apple.com/search?term={q}"),
        b(["netflix", "nf"], "Netflix", "https://www.netflix.com/search?q={q}"),
        b(["perp", "perplexity", "pplx"], "Perplexity", "https://www.perplexity.ai/search?q={q}"),
        b(["claude"], "Claude", "https://claude.ai/new?q={q}"),
        b(["chatgpt", "gpt"], "ChatGPT", "https://chatgpt.com/?q={q}"),
    ]

    /// Anything else ("!wiktionary cats") goes to DuckDuckGo with the bang, and DuckDuckGo sends
    /// it on. Only the bang word is checked here: letters, digits, "-", "_" or ".".
    public static func fallback(trigger: String) -> Bang? {
        let ok = !trigger.isEmpty && trigger.count <= 30
            && trigger.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
        guard ok else { return nil }
        let t = trigger.lowercased()
        return Bang(trigger: t, name: "DuckDuckGo !\(t)", template: "https://duckduckgo.com/?q=!\(t)%20{q}",
                    home: "https://duckduckgo.com/?q=!\(t)", isFallback: true)
    }

    private static func b(_ triggers: [String], _ name: String, _ template: String) -> Bang {
        let home = URL(string: template.replacingOccurrences(of: "{q}", with: "x"))
            .flatMap { u in u.host().map { "\(u.scheme ?? "https")://\($0)" } } ?? template
        return Bang(trigger: triggers[0], name: name, template: template, home: home, aliases: Array(triggers.dropFirst()))
    }

    private static let byTrigger: [String: Bang] = Dictionary(
        all.flatMap { b in ([b.trigger] + b.aliases).map { ($0, b) } }, uniquingKeysWith: { a, _ in a })

    /// One of ours, else DuckDuckGo's.
    public static func bang(for trigger: String) -> Bang? { byTrigger[trigger.lowercased()] ?? fallback(trigger: trigger) }

    /// "!yt cats", "cats !yt" or "!yt". Nil when there's no known bang.
    public static func resolve(_ text: String) -> (bang: Bang, query: String, url: URL)? {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return nil }
        var found: (Bang, Int)?
        if let first = words.first, first.count > 1, first.hasPrefix("!"), let b = bang(for: String(first.dropFirst())) {
            found = (b, 0)
        } else if words.count > 1, let last = words.last, last.count > 1, last.hasPrefix("!"), let b = bang(for: String(last.dropFirst())) {
            found = (b, words.count - 1)
        }
        guard let (bang, index) = found else { return nil }
        var rest = words
        rest.remove(at: index)
        let query = rest.joined(separator: " ")
        if query.isEmpty {
            guard let url = URL(string: bang.home) else { return nil }
            return (bang, "", url)
        }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? query
        guard let url = URL(string: bang.template.replacingOccurrences(of: "{q}", with: encoded)) else { return nil }
        return (bang, query, url)
    }

    /// Bangs whose trigger starts with what's typed after "!", for hints.
    public static func completions(for partial: String, limit: Int = 4) -> [Bang] {
        let p = partial.lowercased()
        return all.filter { b in ([b.trigger] + b.aliases).contains { $0.hasPrefix(p) } }.sorted { $0.trigger.count < $1.trigger.count }.prefix(limit).map { $0 }
    }
}

extension CharacterSet {
    /// Characters that can stand unescaped in a query value ("&", "=", "+", "#" can't).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#?/")
        return set
    }()
}
