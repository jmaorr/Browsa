import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// Live Folders: a pinned folder that fills itself from somewhere, like Arc's. Each thing the source
// lists (a feed's article, a pull request waiting for your review) becomes a pinned tab in the
// folder, marked new until you open it. Things the source stops listing go away; a tab you take
// out of the folder (or unpin) is yours and the folder won't bring it back.
//
// Everything here is pure and works on values, so the merge rules are easy to test. The Mac app
// fetches, then applies the plan.

/// Where a live folder's items come from.
public enum LiveSourceKind: Codable, Equatable, Hashable, Sendable {
    /// An RSS or Atom feed.
    case feed(url: URL)
    /// A GitHub search for issues and pull requests (`is:open is:pr review-requested:@me`).
    case github(query: String)

    /// The GitHub searches offered when making a folder.
    public static let githubPresets: [(name: String, query: String)] = [
        ("Review requests", "is:open is:pr review-requested:@me archived:false"),
        ("My pull requests", "is:open is:pr author:@me archived:false"),
        ("Assigned to me", "is:open assignee:@me archived:false"),
    ]

    /// A short line saying where items come from, for menus and the edit sheet.
    public var summary: String {
        switch self {
        case .feed(let url): url.host() ?? url.absoluteString
        case .github(let query):
            Self.githubPresets.first { $0.query == query }.map { "GitHub · \($0.name)" } ?? "GitHub · \(query)"
        }
    }
}

/// One thing a live folder holds: the item it came from and the pinned tab showing it.
public struct LiveItem: Codable, Equatable, Hashable, Sendable {
    /// The source's id for it (a feed entry's guid or link, an issue's URL). Stable across fetches.
    public var key: String
    public var tabID: UUID
    public var title: String
    public var url: URL
    /// Not opened yet.
    public var unread: Bool

    public init(key: String, tabID: UUID, title: String, url: URL, unread: Bool = true) {
        self.key = key
        self.tabID = tabID
        self.title = title
        self.url = url
        self.unread = unread
    }
}

/// What makes a pinned folder live: its source, what it holds, and what you've taken out of it.
public struct LiveSource: Codable, Equatable, Sendable {
    public var kind: LiveSourceKind
    /// Newest first, as the folder shows them.
    public var items: [LiveItem]
    /// Keys of items you took out of the folder. They don't come back.
    public var dismissed: [String]
    public var lastChecked: Date?
    /// Why the last check failed, if it did, in words for the folder's menu.
    public var lastError: String?

    public init(kind: LiveSourceKind, items: [LiveItem] = [], dismissed: [String] = [],
                lastChecked: Date? = nil, lastError: String? = nil) {
        self.kind = kind
        self.items = items
        self.dismissed = dismissed
        self.lastChecked = lastChecked
        self.lastError = lastError
    }

    public var unreadCount: Int { items.filter(\.unread).count }
}

/// An item as a source lists it, before it has a tab.
public struct FetchedItem: Equatable, Sendable {
    public var key: String
    public var title: String
    public var url: URL
    public var date: Date?

    public init(key: String, title: String, url: URL, date: Date? = nil) {
        self.key = key
        self.title = title
        self.url = url
        self.date = date
    }
}

/// What to do to a live folder after a fetch.
public struct LivePlan: Equatable, Sendable {
    /// The folder's source as it should be now.
    public var source: LiveSource
    /// New items, newest first, each with the id its new tab takes.
    public var added: [LiveItem]
    /// Tabs to take away: their items aren't listed any more.
    public var removed: [UUID]
}

public enum LiveFolders {
    /// How many items a live folder holds at most.
    public static let limit = 25
    /// How many dismissed keys are remembered (the oldest are forgotten).
    static let dismissedLimit = 500

    /// Fits what's been fetched into the folder.
    ///
    /// - `inFolder`: the tabs in the folder now (anywhere inside it). An item whose tab isn't there
    ///   was taken out (or unpinned), so it stops being the folder's and won't come back.
    /// - `keep`: tabs not to take away even if their item is gone, such as the one on screen.
    /// - `newID`: the id for each new item's tab (a parameter so tests can be exact).
    public static func plan(_ source: LiveSource, fetched: [FetchedItem], inFolder: Set<UUID>,
                            keep: Set<UUID> = [], limit: Int = LiveFolders.limit,
                            newID: () -> UUID = UUID.init) -> LivePlan {
        var out = source
        var dismissed = source.dismissed
        // Items whose tab left the folder are no longer the folder's.
        let taken = source.items.filter { !inFolder.contains($0.tabID) }
        for item in taken where !dismissed.contains(item.key) { dismissed.append(item.key) }
        var items = source.items.filter { inFolder.contains($0.tabID) }

        // Newest first; feeds without dates keep their own order.
        var seen = Set<String>()
        let listed = fetched
            .enumerated()
            .sorted { a, b in
                switch (a.element.date, b.element.date) {
                case let (x?, y?) where x != y: x > y
                default: a.offset < b.offset
                }
            }
            .map(\.element)
            .filter { seen.insert($0.key).inserted }
            .prefix(limit)
        let listedKeys = Set(listed.map(\.key))

        // Gone from the source: away, unless it's being kept.
        var removed: [UUID] = []
        items = items.filter { item in
            if listedKeys.contains(item.key) || keep.contains(item.tabID) { return true }
            removed.append(item.tabID)
            return false
        }
        // Still listed: titles and links follow the source.
        let byKey = Dictionary(listed.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        items = items.map { item in
            guard let f = byKey[item.key] else { return item }
            var item = item
            item.title = f.title
            return item
        }

        let have = Set(items.map(\.key))
        let dismissedSet = Set(dismissed)
        let added = listed
            .filter { !have.contains($0.key) && !dismissedSet.contains($0.key) }
            .map { LiveItem(key: $0.key, tabID: newID(), title: $0.title, url: $0.url, unread: true) }

        // In the source's order: the new ones where they're listed, newest at the top.
        let order = Dictionary(listed.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: { a, _ in a })
        out.items = (items + added).sorted { (order[$0.key] ?? Int.max) < (order[$1.key] ?? Int.max) }
        out.dismissed = Array(dismissed.suffix(dismissedLimit))
        out.lastChecked = .now
        out.lastError = nil
        return LivePlan(source: out, added: added, removed: removed)
    }

    /// The folder's items with this tab marked as opened. Nil when nothing changed.
    public static func markingRead(_ tabID: UUID, in source: LiveSource) -> LiveSource? {
        guard let i = source.items.firstIndex(where: { $0.tabID == tabID && $0.unread }) else { return nil }
        var out = source
        out.items[i].unread = false
        return out
    }

    /// Every live folder in a layout, with its id.
    public static func liveFolders(in layout: [PinnedNode]) -> [PinnedFolder] {
        PinnedOutline.folders(layout).map(\.folder).filter { $0.live != nil }
    }
}

// MARK: Feeds

/// Reads RSS 2.0, RSS 1.0 (RDF) and Atom.
public enum FeedParser {
    public struct Feed: Equatable, Sendable {
        public var title: String
        public var items: [FetchedItem]
    }

    /// The feed in `data`, or nil when it isn't one (an HTML page, say).
    public static func parse(_ data: Data, base: URL? = nil) -> Feed? {
        let delegate = Delegate(base: base)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        guard delegate.isFeed else { return nil }
        return Feed(title: delegate.feedTitle.trimmingCharacters(in: .whitespacesAndNewlines), items: delegate.items)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let base: URL?
        var isFeed = false
        var feedTitle = ""
        var items: [FetchedItem] = []

        private var stack: [String] = []
        private var text = ""
        private var entry: [String: String]?
        private var entryLink: String?

        init(base: URL?) { self.base = base }

        private func local(_ name: String) -> String {
            (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let el = local(name)
            if stack.isEmpty, ["rss", "feed", "rdf"].contains(el) { isFeed = true }
            stack.append(el)
            text = ""
            if el == "item" || el == "entry" {
                entry = [:]
                entryLink = nil
            } else if el == "link", entry != nil, let href = attributes["href"] {
                // Atom: <link rel="alternate" href="…"/>; the alternate (or the first) wins.
                let rel = attributes["rel"] ?? "alternate"
                if rel == "alternate" || entryLink == nil { entryLink = href }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            text += String(decoding: block, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let el = local(name)
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer {
                if !stack.isEmpty { stack.removeLast() }
                text = ""
            }
            if entry != nil {
                switch el {
                case "item", "entry":
                    finishEntry()
                case "title", "guid", "id", "pubdate", "published", "updated", "date":
                    if entry?[el] == nil, !value.isEmpty { entry?[el] = value }
                case "link":
                    if entryLink == nil, !value.isEmpty { entryLink = value }
                default: break
                }
            } else if el == "title", feedTitle.isEmpty, stack.count <= 3 {
                feedTitle = value
            }
        }

        private func finishEntry() {
            defer { entry = nil; entryLink = nil }
            guard let e = entry else { return }
            let link = entryLink ?? e["guid"].flatMap { $0.hasPrefix("http") ? $0 : nil }
            guard let link, let url = URL(string: link, relativeTo: base)?.absoluteURL,
                  url.scheme == "https" || url.scheme == "http" else { return }
            let title = Self.plain(e["title"] ?? "")
            let date = [e["pubdate"], e["published"], e["updated"], e["date"]].lazy.compactMap { $0.flatMap(Self.date) }.first
            items.append(FetchedItem(key: e["guid"] ?? e["id"] ?? url.absoluteString,
                                     title: title.isEmpty ? (url.host() ?? url.absoluteString) : title,
                                     url: url, date: date))
        }

        /// Titles sometimes carry HTML entities or tags.
        static func plain(_ s: String) -> String {
            var out = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                   ("&#39;", "'"), ("&apos;", "'"), ("&#8217;", "’"), ("&#8216;", "‘"),
                                   ("&#8220;", "“"), ("&#8221;", "”"), ("&#8211;", "–"), ("&#8212;", "—"), ("&nbsp;", " ")] {
                out = out.replacingOccurrences(of: entity, with: char)
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func date(_ s: String) -> Date? {
            if let d = try? Date(s, strategy: .iso8601) { return d }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z",
                           "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
                f.dateFormat = format
                if let d = f.date(from: s) { return d }
            }
            return nil
        }
    }
}

/// Finds a page's feeds from its `<link rel="alternate" type="application/rss+xml" href="…">` tags.
public enum FeedDiscovery {
    public static func feedLinks(inHTML html: String, base: URL) -> [URL] {
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return tag.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let link = ns.substring(with: m.range)
            let attrs = attributes(link)
            guard attrs["rel"]?.lowercased().split(separator: " ").contains("alternate") == true,
                  let type = attrs["type"]?.lowercased(),
                  type.contains("rss") || type.contains("atom"),
                  let href = attrs["href"] else { return nil }
            return URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: base)?.absoluteURL
        }
    }

    private static func attributes(_ tag: String) -> [String: String] {
        guard let re = try? NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)") else { return [:] }
        let ns = tag as NSString
        var out: [String: String] = [:]
        for m in re.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            var value = ns.substring(with: m.range(at: 2))
            if value.hasPrefix("\"") || value.hasPrefix("'") { value = String(value.dropFirst().dropLast()) }
            out[key] = value
        }
        return out
    }
}

// MARK: GitHub

public enum GitHubSearch {
    /// The search API request for a query. `@me` needs a token.
    public static func request(query: String, token: String?) -> URLRequest {
        var c = URLComponents(string: "https://api.github.com/search/issues")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "sort", value: "updated"),
                        URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "per_page", value: "\(LiveFolders.limit)")]
        var r = URLRequest(url: c.url!)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("Browsa", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            let html_url: URL
            let title: String
            let number: Int
            let updated_at: Date?
            let repository_url: String?
        }
        let items: [Item]
    }

    /// The items in a search response, titled "Title · repo#123" so pull requests from different
    /// repositories tell apart. The newest update first.
    public static func items(from data: Data) throws -> [FetchedItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data).items.map { item in
            let repo = item.repository_url?.split(separator: "/").last.map(String.init)
            let title = repo.map { "\(item.title) · \($0)#\(item.number)" } ?? "\(item.title) #\(item.number)"
            return FetchedItem(key: item.html_url.absoluteString, title: title, url: item.html_url, date: item.updated_at)
        }
    }

    /// GitHub's error message in a failed response, if it sent one.
    public static func message(from data: Data) -> String? {
        struct E: Decodable { let message: String }
        return (try? JSONDecoder().decode(E.self, from: data))?.message
    }
}
