#if os(macOS)
import AppKit
import WebKit

/// Chrome's `offscreen` documents for WebKit. WebKit has no `chrome.offscreen`, so the compat script's
/// stand-in sends `{action: "create", url}`, `{action: "close"}` or `{action: "has"}` over native
/// messaging to `browsa.offscreen`, and Browsa keeps a hidden extension page for it: one per
/// extension, as in Chrome. "create" answers once the page has loaded, so the extension can message
/// it straight away (Paper Snapshot writes the clipboard from its offscreen page right after making it).
@available(macOS 15.4, *)
@MainActor
final class ExtensionOffscreen: NSObject, WKNavigationDelegate {
    static let applicationIdentifier = "browsa.offscreen"
    private static var documents: [String: ExtensionOffscreen] = [:]

    private let web: WKWebView
    private let url: URL
    private var waiting: [(Any?, (any Error)?) -> Void] = []
    private var loaded = false

    private init(context: WKWebExtensionContext, configuration: WKWebViewConfiguration, url: URL) {
        configuration.preferences.inactiveSchedulingPolicy = .none
        // Copying without a click goes through the compat script's fallback (see writeClipboard).
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        self.url = url
        super.init()
        web.navigationDelegate = self
        web.load(URLRequest(url: url))
    }

    static func handle(_ message: Any, for context: WKWebExtensionContext, reply: @escaping (Any?, (any Error)?) -> Void) {
        let body = message as? [String: Any] ?? [:]
        let id = context.uniqueIdentifier
        switch body["action"] as? String {
        case "create":
            guard let path = body["url"] as? String, let url = documentURL(path, base: context.baseURL) else {
                reply(nil, error("offscreen.createDocument needs a page inside the extension"))
                return
            }
            if let existing = documents[id] {
                existing.whenLoaded(reply)
                return
            }
            guard let configuration = context.webViewConfiguration else {
                reply(nil, error("The extension isn't running"))
                return
            }
            let document = ExtensionOffscreen(context: context, configuration: configuration, url: url)
            documents[id] = document
            document.whenLoaded(reply)
        case "close":
            documents.removeValue(forKey: id)?.web.stopLoading()
            reply(nil, nil)
        case "has":
            reply(documents[id].map { $0.url.absoluteString } ?? false, nil)
        default:
            reply(nil, error("Unknown offscreen action"))
        }
    }

    /// `browsa.clipboard`: `{items: {mimeType: text}}` from the compat script's copy stand-in. Only for
    /// extensions that asked for clipboardWrite, as in Chrome.
    static let clipboardIdentifier = "browsa.clipboard"

    static func writeClipboard(_ message: Any, for context: WKWebExtensionContext, reply: @escaping (Any?, (any Error)?) -> Void) {
        guard context.hasPermission(.clipboardWrite) else {
            reply(nil, error("The extension didn't ask for clipboardWrite"))
            return
        }
        guard let items = (message as? [String: Any])?["items"] as? [String: String], !items.isEmpty else {
            reply(false, nil)
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        for (type, text) in items {
            switch type.lowercased() {
            case "text/html": board.setString(text, forType: .html)
            case "text/plain": board.setString(text, forType: .string)
            default: board.setString(text, forType: NSPasteboard.PasteboardType(type))
            }
        }
        // Paste targets that only take plain text still get something.
        if items["text/plain"] == nil, let html = items["text/html"] { board.setString(html, forType: .string) }
        reply(true, nil)
    }

    static func close(for context: WKWebExtensionContext) {
        documents.removeValue(forKey: context.uniqueIdentifier)
    }

    /// A relative path, or a URL inside the extension, resolved against its base URL.
    private static func documentURL(_ path: String, base: URL) -> URL? {
        if let absolute = URL(string: path), absolute.scheme != nil {
            return absolute.host == base.host && absolute.scheme == base.scheme ? absolute : nil
        }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !trimmed.isEmpty, !trimmed.contains("..") else { return nil }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    private static func error(_ text: String) -> NSError {
        NSError(domain: "Browsa.Extensions", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private func whenLoaded(_ reply: @escaping (Any?, (any Error)?) -> Void) {
        if loaded { reply(true, nil) } else { waiting.append(reply) }
    }

    private func finish(_ error: (any Error)?) {
        loaded = error == nil
        let replies = waiting
        waiting = []
        for reply in replies { reply(error == nil ? true : nil, error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finish(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finish(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finish(error) }
    }
}
#endif
