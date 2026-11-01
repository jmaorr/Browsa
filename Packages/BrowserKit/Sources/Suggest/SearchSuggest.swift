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
            // Unofficial endpoint used by most third-party browsers. Returns ["q", ["s1", "s2", ...]].
            c = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
            c.queryItems = [.init(name: "client", value: "firefox"), .init(name: "q", value: query)]
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
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
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

/// Remote search suggestions. Cancellation-aware: the engine cancels the task when the
/// user types again, and URLSession honours task cancellation.
public struct SearchSuggestProvider: SuggestionProvider {
    public let engine: SearchEngine
    let session: URLSession

    public var isRemote: Bool { true }

    public init(engine: SearchEngine, session: URLSession = .shared) {
        self.engine = engine
        self.session = session
    }

    public func suggestions(for query: String, limit: Int) async -> [Suggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let (data, response) = try? await session.data(for: engine.suggestRequest(for: trimmed)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return engine.parseSuggestions(data)
            .filter { $0.lowercased() != trimmed.lowercased() }
            .prefix(limit)
            .enumerated()
            .map { i, text in
                Suggestion(kind: .searchSuggestion, title: text, action: .search(text),
                           score: 1.0 - Double(i) * 0.01)
            }
    }
}
