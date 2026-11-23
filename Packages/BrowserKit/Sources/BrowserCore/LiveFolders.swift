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
    /// Arc's GitHub folder: your open pull requests and the reviews asked of you and your teams,
    /// read with the space's own GitHub login.
    case githubPullRequests

    /// The GitHub searches offered when making a folder.
    public static let githubPresets: [(name: String, query: String)] = [
        ("Review requests", "is:open is:pr review-requested:@me archived:false"),
        ("My pull requests", "is:open is:pr author:@me archived:false"),
        ("Assigned to me", "is:open is:pr assignee:@me archived:false"),
    ]

    /// Read with the space's github.com login.
    public var usesGitHubLogin: Bool {
        switch self {
        case .feed: false
        case .github, .githubPullRequests: true
        }
    }

    /// A short line saying where items come from, for menus and the edit sheet.
    public var summary: String {
        switch self {
        case .feed(let url): url.host() ?? url.absoluteString
        case .githubPullRequests: "GitHub · your pull requests and review requests"
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

// MARK: GitHub, signed in as you

/// Reads your pull requests from github.com itself, with the space's own GitHub login, the way Arc
/// and Dia did: no token, no sign-in of Browsa's own. GitHub answers `/pulls?q=…` with JSON when
/// asked for it, and the search page as a fallback; the reader also takes the page's embedded data
/// and the classic list, since GitHub changes these. Ported from Cra's GitHub live folder plugin
/// (github.com/VictorKildahl/cra, resources/live-folder-plugins/github/main.js, MIT, © 2026 Victor Kildahl).
public enum GitHubPulls {
    public enum Failure: Error, Equatable, Sendable {
        case notSignedIn, rateLimited, unexpectedPage
        public var message: String {
            switch self {
            case .notSignedIn: "Sign in to GitHub in this space to fill this folder."
            case .rateLimited: "GitHub asked Browsa to slow down. It'll try again shortly."
            case .unexpectedPage: "GitHub answered in a way Browsa didn't understand."
            }
        }
    }

    /// Arc's three: pull requests you opened, reviews asked of you, and of your teams.
    public static let arcQueries = [
        "is:pr is:open archived:false author:@me sort:updated-desc",
        "is:pr is:open archived:false user-review-requested:@me sort:updated-desc",
        "is:pr is:open archived:false review-requested:@me sort:updated-desc",
    ]

    /// The requests for one search: the pulls dashboard first, then the search page.
    public static func requests(query: String) -> [URLRequest] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=#"))) ?? query
        return ["https://github.com/pulls?q=\(q)", "https://github.com/search?q=\(q)&type=pullrequests"].compactMap { s in
            guard let url = URL(string: s) else { return nil }
            var r = URLRequest(url: url)
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            r.setValue("true", forHTTPHeaderField: "GitHub-Verified-Fetch")
            return r
        }
    }

    /// Reads one answer. `finalURL` is where redirects ended (a sign-in page means signed out).
    public static func read(_ data: Data, status: Int, finalURL: URL?) -> Result<[FetchedItem], Failure> {
        let body = String(decoding: data, as: UTF8.self)
        let path = finalURL?.path() ?? ""
        if path == "/login" || path.hasPrefix("/session") || path.hasSuffix("/sso") { return .failure(.notSignedIn) }
        if status == 429 || (status == 403 && body.range(of: "rate limit", options: .caseInsensitive) != nil) { return .failure(.rateLimited) }
        if status == 401 || (body.count < 2000 && body.range(of: "authenticate you", options: .caseInsensitive) != nil)
            || body.contains("\"logged_in\":false") { return .failure(.notSignedIn) }
        guard (200..<300).contains(status) else { return .failure(.unexpectedPage) }
        var items: [FetchedItem] = []
        let trimmed = body.drop { $0.isWhitespace }
        if trimmed.first == "{" || trimmed.first == "[" {
            guard let json = try? JSONSerialization.jsonObject(with: data) else { return .failure(.unexpectedPage) }
            items = parse(json)
        } else {
            // Signed-out pages name no one.
            if body.contains("name=\"user-login\" content=\"\"") { return .failure(.notSignedIn) }
            for script in matches("<script[^>]*type=\"application/json\"[^>]*>([\\s\\S]*?)</script>", in: body) {
                if let json = try? JSONSerialization.jsonObject(with: Data(script[1].utf8)) { items += parse(json) }
            }
            if items.isEmpty { items = parseClassic(body) }
            if items.isEmpty, !body.contains("blankslate") { return .failure(.unexpectedPage) }
        }
        return .success(unique(items))
    }

    /// Pull requests found anywhere in GitHub's JSON, open ones only (drafts too).
    static func parse(_ root: Any) -> [FetchedItem] {
        var out: [FetchedItem] = []
        func walk(_ value: Any, depth: Int) {
            guard depth < 40 else { return }
            if let d = value as? [String: Any] {
                if let item = item(d) {
                    if isOpen(d) { out.append(item) }
                    return
                }
                for v in d.values { walk(v, depth: depth + 1) }
            } else if let a = value as? [Any] {
                for v in a { walk(v, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return out
    }

    private static func item(_ d: [String: Any]) -> FetchedItem? {
        let type = (d["__typename"] as? String) ?? (d["type"] as? String) ?? ""
        if !type.isEmpty, type != "PullRequest", !type.lowercased().contains("pull") { return nil }
        guard let number = (d["number"] as? Int) ?? (d["num"] as? Int),
              let rawTitle = (d["title"] as? String) ?? (d["hl_title"] as? String) ?? (d["titleHTML"] as? String) else { return nil }
        let link = ["url", "permalink", "html_url", "resourcePath", "path", "href"].lazy.compactMap { d[$0] as? String }.first
        let fromLink = link.flatMap(pullPath)
        let repo = fromLink?.number == number ? fromLink?.repo : repository(d["repository"] ?? d["repo"] ?? d["repoNameWithOwner"] ?? d["repository_nwo"])
        guard let repo else { return nil }
        let looksLikePR = link?.contains("/pull/") == true || type == "PullRequest" || d["isDraft"] != nil || d["is_draft"] != nil
            || d["reviewDecision"] != nil || d["pull_request"] != nil || d["merged"] != nil || d["num"] != nil
            || ((d["issue"] as? [String: Any])?["issue"] as? [String: Any])?["pull_request_id"] != nil
        guard looksLikePR, let url = URL(string: "https://github.com/\(repo)/pull/\(number)") else { return nil }
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        let date = ["updatedAt", "updated_at", "updated", "createdAt", "created_at", "created"].lazy
            .compactMap { (d[$0] as? String).flatMap { try? Date($0, strategy: .iso8601) } }.first
        return FetchedItem(key: url.absoluteString, title: "\(plain(rawTitle)) · \(name)#\(number)", url: url, date: date)
    }

    private static func isOpen(_ d: [String: Any]) -> Bool {
        let state = ((d["state"] as? String) ?? "").lowercased()
        let set = { (k: String) in d[k] != nil && !(d[k] is NSNull) }
        return state != "merged" && state != "closed" && (d["merged"] as? Bool) != true && (d["closed"] as? Bool) != true
            && !set("mergedAt") && !set("merged_at") && !set("closedAt") && !set("closed_at")
    }

    private static func repository(_ value: Any?) -> String? {
        if let s = value as? String { return s.split(separator: "/").count == 2 ? s : nil }
        guard let d = value as? [String: Any] else { return nil }
        if let inner = d["repository"] { return repository(inner) }
        if let nwo = (d["nameWithOwner"] ?? d["name_with_owner"] ?? d["full_name"]) as? String { return repository(nwo) }
        let owner = ((d["owner"] as? [String: Any]).flatMap { ($0["login"] ?? $0["displayLogin"]) as? String })
            ?? (d["owner"] as? String) ?? (d["owner_login"] as? String) ?? (d["ownerLogin"] as? String)
        guard let owner, let name = d["name"] as? String else { return nil }
        return "\(owner)/\(name)"
    }

    public static func pullPath(_ link: String) -> (repo: String, number: Int)? {
        guard let m = matches("(?:^|github\\.com)/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\\d+)", in: link).first,
              let n = Int(m[3]) else { return nil }
        return ("\(m[1])/\(m[2])", n)
    }

    /// The list GitHub drew before its React dashboard.
    static func parseClassic(_ html: String) -> [FetchedItem] {
        let chunks = html.components(separatedBy: "js-issue-row").dropFirst()
        return chunks.compactMap { chunk -> FetchedItem? in
            if chunk.range(of: "octicon-git-(merge|pull-request-closed)(?![\\w-])", options: .regularExpression) != nil { return nil }
            for a in matches("<a\\b([^>]*)>([\\s\\S]*?)</a>", in: chunk) {
                guard let href = matches("href=\"([^\"]*)\"", in: a[1]).first?[1], let p = pullPath(href),
                      href.hasSuffix("/pull/\(p.number)"),
                      a[1].contains("data-hovercard-type=\"pull_request\"") || a[1].contains("js-navigation-open") || a[1].contains("markdown-title")
                else { continue }
                let title = plain(a[2])
                guard !title.isEmpty, let url = URL(string: "https://github.com/\(p.repo)/pull/\(p.number)") else { continue }
                let name = p.repo.split(separator: "/").last.map(String.init) ?? p.repo
                return FetchedItem(key: url.absoluteString, title: "\(title) · \(name)#\(p.number)", url: url)
            }
            return nil
        }
    }

    public static func unique(_ items: [FetchedItem]) -> [FetchedItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.key.lowercased()).inserted }
    }

    private static func plain(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (e, c) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: e, with: c)
        }
        return out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        }
    }
}
