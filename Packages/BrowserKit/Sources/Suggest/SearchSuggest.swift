import Foundation

public enum SearchEngine: Hashable, Sendable, Codable {
    case google
    case duckDuckGo
    /// Brave Search Suggest API (official, needs a subscription token; free tier available).
    case brave(apiKey: String)

    public var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .brave: "Brave"
        }
    }

    public func searchURL(for query: String) -> URL {
        var c: URLComponents
        switch self {
        case .google: c = URLComponents(string: "https://www.google.com/search")!
        case .duckDuckGo: c = URLComponents(string: "https://duckduckgo.com/")!
        case .brave: c = URLComponents(string: "https://search.brave.com/search")!
        }
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url!
    }

    func suggestRequest(for query: String) -> URLRequest {
        var c: URLComponents
        switch self {
        case .google:
            // Unofficial endpoint used by most third-party browsers. The "chrome" client adds
            // suggestion types (QUERY / NAVIGATION) and relevance scores to ["q", [s...]].
            c = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
            c.queryItems = [.init(name: "client", value: "chrome"), .init(name: "q", value: query)]
        case .duckDuckGo:
            // Unofficial. With type=list returns ["q", ["s1", ...]].
            c = URLComponents(string: "https://duckduckgo.com/ac/")!
            c.queryItems = [.init(name: "q", value: query), .init(name: "type", value: "list")]
        case .brave:
            c = URLComponents(string: "https://api.search.brave.com/res/v1/suggest/search")!
            c.queryItems = [.init(name: "q", value: query), .init(name: "count", value: "8")]
        }
        var req = URLRequest(url: c.url!, timeoutInterval: 2)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if case .brave(let key) = self {
            req.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        }
        return req
    }

    /// Parses a suggest response body into plain query strings.
    public func parseSuggestions(_ data: Data) -> [String] {
        parseHits(data).filter { $0.url == nil }.map(\.text)
    }

    /// Parses a suggest response into queries and, where the engine offers them, site links.
    public func parseHits(_ data: Data) -> [RemoteHit] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        switch self {
        case .google:
            guard let arr = json as? [Any], arr.count >= 2, let list = arr[1] as? [Any] else { return [] }
            let texts = list.compactMap { $0 as? String }
            let meta = arr.count >= 5 ? arr[4] as? [String: Any] : nil
            let types = meta?["google:suggesttype"] as? [String] ?? []
            let rel = (meta?["google:suggestrelevance"] as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue }
            return texts.enumerated().compactMap { i, text in
                let type = i < types.count ? types[i] : "QUERY"
                let relevance = i < rel.count ? rel[i] : nil
                if type == "NAVIGATION" {
                    guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return nil }
                    return RemoteHit(text: URLNormalizer.displayHost(url), url: url, relevance: relevance)
                }
                // Skip calculator/entity/personal rows we can't render faithfully.
                guard type == "QUERY" || type.isEmpty else { return nil }
                return RemoteHit(text: text, url: nil, relevance: relevance)
            }
        default:
            return legacyParse(json).map { RemoteHit(text: $0, url: nil, relevance: nil) }
        }
    }

    private func legacyParse(_ json: Any) -> [String] {
        switch self {
        case .google, .duckDuckGo:
            guard let arr = json as? [Any], arr.count >= 2, let list = arr[1] as? [Any] else { return [] }
            return list.compactMap { $0 as? String }
        case .brave:
            guard let obj = json as? [String: Any],
                  let results = obj["results"] as? [[String: Any]] else { return [] }
            return results.compactMap { $0["query"] as? String }
        }
    }
}

public struct RemoteHit: Hashable, Sendable {
    public let text: String
    public let url: URL?
    /// Engine-provided relevance (Google: roughly 0...1500), if any.
    public let relevance: Double?
}
