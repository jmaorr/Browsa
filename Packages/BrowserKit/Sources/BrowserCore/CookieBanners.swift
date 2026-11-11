#if canImport(WebKit)
import Foundation
import WebKit

/// Declines cookie banners with DuckDuckGo's autoconsent (MPL-2.0), the same engine DuckDuckGo's
/// own iOS browser runs in its WKWebViews.
///
/// The script lives in its own content world, so pages can't see or tamper with it. It finds the
/// site's consent manager (OneTrust, Didomi, Sourcepoint, TrustArc and ~300 more, plus a heuristic
/// for home-grown banners), hides the banner straight away, and clicks through to "reject all".
/// Some consent managers can only be answered from the page's own JavaScript; for those the script
/// asks the app (an "eval" message), which runs that step in the page world and replies.
@MainActor
public final class CookieBannerHandler: NSObject, WKScriptMessageHandler {
    public static let world = WKContentWorld.world(name: "duo.autoconsent")
    public static let messageName = "autoconsent"
    /// Called when a banner was declined on a page, for a quiet confirmation.
    private let onDeclined: @MainActor (WKWebView) -> Void

    public init(onDeclined: @escaping @MainActor (WKWebView) -> Void) {
        self.onDeclined = onDeclined
    }

    /// The user scripts to install, each wrapped so it does nothing on sites the user switched
    /// blockers off for. The full script (about half a megabyte) goes into main frames only, so a
    /// page full of ad and embed iframes doesn't parse it dozens of times. Subframes get a tiny gate
    /// instead: it recognises the few consent managers that draw their banner inside an iframe and
    /// asks for the full script ("loadFrame"), which the handler then loads into that one frame.
    public static func scripts(skipping hosts: Set<String>) -> [WKUserScript] {
        guard let bundle = bundledSource else { return [] }
        let skip = (try? JSONEncoder().encode(hosts.sorted())).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        func wrapped(_ body: String) -> String {
            """
            (function () {
              var skip = \(skip), h = location.hostname;
              if (skip.some(function (d) { return h === d || h.endsWith('.' + d); })) return;
            \(body)
            })();
            """
        }
        var scripts = [WKUserScript(source: wrapped(bundle), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)]
        if let gate = frameGateSource {
            scripts.append(WKUserScript(source: wrapped(gate), injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        }
        return scripts
    }

    private static let bundledSource: String? = Bundle.module.url(forResource: "autoconsent", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    private static let frameGateSource: String? = Bundle.module.url(forResource: "autoconsent-frames", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let webView = message.webView else { return }
        let frame = message.frameInfo
        switch type {
        case "loadFrame":
            // A subframe's gate found a consent manager that lives in frames. The gate already
            // checked the user's allowlist for this frame.
            guard !frame.isMainFrame, let source = Self.bundledSource else { return }
            webView.evaluateJavaScript(source, in: frame, in: Self.world, completionHandler: nil)
        case "eval":
            guard let id = body["id"] as? String, let code = body["code"] as? String else { return }
            Task { @MainActor in
                let raw = try? await webView.callAsyncJavaScript(
                    "try { return !!window.eval(code) } catch (e) { return false }",
                    arguments: ["code": code], in: frame, contentWorld: .page)
                let result = (raw as? Bool) ?? false
                _ = try? await webView.callAsyncJavaScript(
                    "await window.autoconsentReceiveMessage({ type: 'evalResp', id: id, result: result })",
                    arguments: ["id": id, "result": result], in: frame, contentWorld: Self.world)
            }
        case "optOutResult":
            if body["result"] as? Bool == true, body["scheduleSelfTest"] as? Bool != true {
                onDeclined(webView)
            }
        default:
            break
        }
    }
}

#if os(iOS)
extension WebViewPool {
    /// Installs (or removes) the cookie-banner script and its message handler everywhere.
    func setAutoconsent(enabled: Bool, skipping hosts: Set<String>, browser: BrowserState) {
        let scripts = enabled ? CookieBannerHandler.scripts(skipping: hosts) : []
        for c in allContentControllers {
            // Our only user scripts; replace them wholesale when the allowlist changes.
            c.removeAllUserScripts()
            c.removeScriptMessageHandler(forName: CookieBannerHandler.messageName, contentWorld: CookieBannerHandler.world)
            guard !scripts.isEmpty else { continue }
            scripts.forEach(c.addUserScript)
            c.add(CookieBannerHandler { [weak browser] in browser?.cookieBannerDeclined(in: $0) }, contentWorld: CookieBannerHandler.world,
                  name: CookieBannerHandler.messageName)
        }
    }
}

extension BrowserState {
    /// A quiet confirmation, once per page, when the banner on the page you're looking at was declined.
    func cookieBannerDeclined(in webView: WKWebView) {
        guard let tab = currentTab, pool.existingSession(for: tab.id)?.webView === webView else { return }
        let key = webView.url?.absoluteString ?? ""
        guard lastCookieToastURL != key else { return }
        lastCookieToastURL = key
        showToast("Cookie banner declined")
    }
}
#endif
#endif
