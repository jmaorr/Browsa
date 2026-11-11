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
    }

    /// Popular bangs. Short on purpose: the ones people actually type.
    public static let all: [Bang] = [
        b("g", "Google", "https://www.google.com/search?q={q}"),
        b("ddg", "DuckDuckGo", "https://duckduckgo.com/?q={q}"),
        b("b", "Bing", "https://www.bing.com/search?q={q}"),
        b("brave", "Brave Search", "https://search.brave.com/search?q={q}"),
        b("k", "Kagi", "https://kagi.com/search?q={q}"),
        b("eco", "Ecosia", "https://www.ecosia.org/search?q={q}"),
        b("yt", "YouTube", "https://www.youtube.com/results?search_query={q}"),
        b("w", "Wikipedia", "https://en.wikipedia.org/w/index.php?search={q}"),
        b("gh", "GitHub", "https://github.com/search?q={q}&type=repositories"),
        b("ghc", "GitHub Code", "https://github.com/search?q={q}&type=code"),
        b("so", "Stack Overflow", "https://stackoverflow.com/search?q={q}"),
        b("mdn", "MDN", "https://developer.mozilla.org/en-US/search?q={q}"),
        b("npm", "npm", "https://www.npmjs.com/search?q={q}"),
        b("pypi", "PyPI", "https://pypi.org/search/?q={q}"),
        b("crates", "crates.io", "https://crates.io/search?q={q}"),
        b("spi", "Swift Package Index", "https://swiftpackageindex.com/search?query={q}"),
        b("ad", "Apple Developer", "https://developer.apple.com/search/?q={q}"),
        b("caniuse", "Can I use", "https://caniuse.com/?search={q}"),
        b("hn", "Hacker News", "https://hn.algolia.com/?q={q}"),
        b("r", "Reddit", "https://www.reddit.com/search/?q={q}"),
        b("x", "X", "https://x.com/search?q={q}"),
        b("bsky", "Bluesky", "https://bsky.app/search?q={q}"),
        b("li", "LinkedIn", "https://www.linkedin.com/search/results/all/?keywords={q}"),
        b("a", "Amazon", "https://www.amazon.com/s?k={q}"),
        b("ebay", "eBay", "https://www.ebay.com/sch/i.html?_nkw={q}"),
        b("m", "Apple Maps", "https://maps.apple.com/?q={q}"),
        b("gm", "Google Maps", "https://www.google.com/maps/search/{q}"),
        b("osm", "OpenStreetMap", "https://www.openstreetmap.org/search?query={q}"),
        b("imdb", "IMDb", "https://www.imdb.com/find/?q={q}"),
        b("lb", "Letterboxd", "https://letterboxd.com/search/{q}/"),
        b("gi", "Google Images", "https://www.google.com/search?tbm=isch&q={q}"),
        b("un", "Unsplash", "https://unsplash.com/s/photos/{q}"),
        b("gt", "Google Translate", "https://translate.google.com/?sl=auto&tl=en&text={q}"),
        b("deepl", "DeepL", "https://www.deepl.com/translator#auto/en/{q}"),
        b("wa", "Wolfram|Alpha", "https://www.wolframalpha.com/input?i={q}"),
        b("ud", "Urban Dictionary", "https://www.urbandictionary.com/define.php?term={q}"),
        b("wb", "Wayback Machine", "https://web.archive.org/web/*/{q}"),
        b("arxiv", "arXiv", "https://arxiv.org/search/?query={q}&searchtype=all"),
        b("scholar", "Google Scholar", "https://scholar.google.com/scholar?q={q}"),
        b("figma", "Figma Community", "https://www.figma.com/community/search?query={q}"),
        b("dribbble", "Dribbble", "https://dribbble.com/search/{q}"),
        b("sf", "SF Symbols (Hotpot)", "https://hotpot.ai/free-icons?s=sfSymbols&q={q}"),
        b("perp", "Perplexity", "https://www.perplexity.ai/search?q={q}"),
        b("claude", "Claude", "https://claude.ai/new?q={q}"),
        b("chatgpt", "ChatGPT", "https://chatgpt.com/?q={q}"),
    ]

    private static func b(_ trigger: String, _ name: String, _ template: String) -> Bang {
        let home = URL(string: template.replacingOccurrences(of: "{q}", with: "x"))
            .flatMap { u in u.host().map { "\(u.scheme ?? "https")://\($0)" } } ?? template
        return Bang(trigger: trigger, name: name, template: template, home: home)
    }

    private static let byTrigger: [String: Bang] = Dictionary(all.map { ($0.trigger, $0) }, uniquingKeysWith: { a, _ in a })

    public static func bang(for trigger: String) -> Bang? { byTrigger[trigger.lowercased()] }

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
        return all.filter { $0.trigger.hasPrefix(p) }.sorted { $0.trigger.count < $1.trigger.count }.prefix(limit).map { $0 }
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
