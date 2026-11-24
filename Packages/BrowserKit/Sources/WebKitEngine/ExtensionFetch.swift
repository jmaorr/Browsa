#if os(macOS)
import Foundation
import WebKit

/// `fetch(url, { credentials: 'include' })` from an extension, with the site's cookies. In Chrome an
/// extension with access to a site sends that site's cookies; WebKit sends none from an extension's
/// origin, so Claude's side panel asked claude.ai whether you were signed in and was told no. The
/// compat script hands such requests to `browsa.fetch`, which makes them with the cookies of the profile
/// the extension is working in (the focused window's tab) and keeps what the site sets there. Private
/// windows get none. Streams are left to WebKit.
///
/// The idea is Search's (Office Commun, MIT, ExtensionFetch.swift).
@available(macOS 15.4, *)
@MainActor
enum ExtensionFetch {
    static let bridgeName = "browsa.fetch"
    /// Bodies over this aren't carried across (they're base64 in a native message).
    static let cap = 16 << 20

    /// Redirects followed before giving up, as browsers do.
    static let maxRedirects = 10

    /// Makes the request with the cookies of `store`: the profile of the window the extension is
    /// working in. Each redirect is followed by hand, so every hop is checked against `hasAccess`
    /// and gets only its own site's cookies.
    static func handle(_ body: [String: Any], store: WKHTTPCookieStore, hasAccess: @escaping (URL) -> Bool,
                       reply: @escaping (Any?, (any Error)?) -> Void) {
        guard let string = body["url"] as? String, let url = URL(string: string), allowed(url, hasAccess: hasAccess) else {
            return reply(nil, error("This extension doesn't have access to that site"))
        }
        var request = URLRequest(url: url, cachePolicy: (body["noStore"] as? Bool ?? false) ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy)
        request.httpMethod = (body["method"] as? String)?.uppercased() ?? "GET"
        for (name, value) in body["headers"] as? [String: String] ?? [:] where name.lowercased() != "cookie" {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let encoded = body["body"] as? String, let data = Data(base64Encoded: encoded) { request.httpBody = data }
        request.httpShouldHandleCookies = false
        let follow = (body["redirect"] as? String ?? "follow") == "follow"
        Task { @MainActor in
            let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                var hops = 0
                while true {
                    guard let target = request.url else { return reply(nil, error("Failed to fetch")) }
                    request.setValue(nil, forHTTPHeaderField: "Cookie")
                    let cookies = await store.allCookies().filter { Self.matches($0, target) }
                    for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { return reply(nil, error("Failed to fetch")) }
                    var headers: [String: String] = [:]
                    for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
                    // What the site set, kept for that profile's tabs as a browser would.
                    for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: target) { await store.setCookie(cookie) }
                    headers["set-cookie"] = nil
                    if follow, (300...399).contains(http.statusCode), http.statusCode != 304,
                       let location = headers["location"], let next = URL(string: location, relativeTo: target)?.absoluteURL {
                        hops += 1
                        guard hops <= maxRedirects else { return reply(nil, error("Too many redirects")) }
                        // A redirect to a site the extension can't reach stops here, as a blocked request.
                        guard allowed(next, hasAccess: hasAccess) else {
                            return reply(nil, error("This extension doesn't have access to that site"))
                        }
                        request = Self.redirected(request, to: next, status: http.statusCode)
                        continue
                    }
                    guard data.count <= cap else { return reply(nil, error("Response too large")) }
                    return reply(["status": http.statusCode, "headers": headers, "url": target.absoluteString,
                                  "body": data.base64EncodedString()], nil)
                }
            } catch {
                reply(nil, Self.error(error.localizedDescription))
            }
        }
    }

    /// The next request in a redirect, as fetch makes it: 303 (and 301/302 after a POST) becomes a GET
    /// without a body. Headers that only belong to the first site go when the site changes.
    nonisolated static func redirected(_ request: URLRequest, to url: URL, status: Int) -> URLRequest {
        var next = request
        next.url = url
        if status == 303 || ((status == 301 || status == 302) && request.httpMethod == "POST") {
            next.httpMethod = "GET"
            next.httpBody = nil
            next.setValue(nil, forHTTPHeaderField: "Content-Type")
            next.setValue(nil, forHTTPHeaderField: "Content-Length")
        }
        if request.url?.host()?.lowercased() != url.host()?.lowercased() {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        next.setValue(nil, forHTTPHeaderField: "Cookie")
        return next
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
