#if os(macOS)
import Foundation
import WebKit

/// `fetch(url, { credentials: 'include' })` from an extension, with the site's cookies. In Chrome an
/// extension with access to a site sends that site's cookies; WebKit sends none from an extension's
/// origin, so Claude's side panel asked claude.ai whether you were signed in and was told no. The
/// compat script hands such requests to `browsa.fetch`, which makes them with the cookies the tabs use
/// (WKWebsiteDataStore.default()) and keeps what the site sets. Streams are left to WebKit.
///
/// The idea is Search's (Office Commun, MIT, ExtensionFetch.swift).
@available(macOS 15.4, *)
@MainActor
enum ExtensionFetch {
    static let bridgeName = "browsa.fetch"
    /// Bodies over this aren't carried across (they're base64 in a native message).
    static let cap = 16 << 20

    static func handle(_ body: [String: Any], reply: @escaping (Any?, (any Error)?) -> Void) {
        guard let string = body["url"] as? String, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return reply(nil, error("Only http(s) requests go through Browsa"))
        }
        var request = URLRequest(url: url, cachePolicy: (body["noStore"] as? Bool ?? false) ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy)
        request.httpMethod = (body["method"] as? String)?.uppercased() ?? "GET"
        for (name, value) in body["headers"] as? [String: String] ?? [:] where name.lowercased() != "cookie" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let encoded = body["body"] as? String, let data = Data(base64Encoded: encoded) { request.httpBody = data }
        request.httpShouldHandleCookies = false
        let follow = (body["redirect"] as? String ?? "follow") == "follow"
        let store = WKWebsiteDataStore.default().httpCookieStore
        Task { @MainActor in
            let cookies = await store.allCookies().filter { Self.matches($0, url) }
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
            let session = URLSession(configuration: .ephemeral, delegate: follow ? nil : NoRedirects(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return reply(nil, error("Failed to fetch")) }
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
                // What the site set, kept for the tabs as a browser would.
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) { await store.setCookie(cookie) }
                headers["set-cookie"] = nil
                guard data.count <= cap else { return reply(nil, error("Response too large")) }
                reply(["status": http.statusCode, "headers": headers, "url": http.url?.absoluteString ?? string,
                       "body": data.base64EncodedString()], nil)
            } catch {
                reply(nil, Self.error(error.localizedDescription))
            }
        }
    }

    /// Whether an extension may make a credentialed request to `url`: http(s) only, and only to a
    /// site it has been given access to.
    nonisolated static func allowed(_ url: URL, hasAccess: (URL) -> Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return false }
        return hasAccess(url)
    }

    /// The cookies a browser would send with a request to `url`.
    nonisolated static func matches(_ cookie: HTTPCookie, _ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if let expires = cookie.expiresDate, expires < Date() { return false }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        let domain = cookie.domain.lowercased()
        let hostMatches = domain.hasPrefix(".")
            ? host == String(domain.dropFirst()) || host.hasSuffix(domain)
            : host == domain
        guard hostMatches else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix(cookie.path)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Browsa.Fetch", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
#endif
