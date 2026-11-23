#if os(macOS)
import Foundation
import WebKit
import BrowserEngine

/// Chrome's sign-in for extensions. An extension sends its OAuth provider to redirect to
/// `https://<its id>.chromiumapp.org/…`, an address that never loads: Chrome catches it.
///
/// - `chrome.identity.launchWebAuthFlow` (compat script → `browsa.identity`): the provider opens in
///   a tab (interactive) or a hidden view (not), and the flow ends with the redirect's URL.
/// - An extension that opens the provider in a tab itself and watches `tabs.onUpdated` for the
///   redirect (Grammarly): the tab is given the redirect address with an empty page, without asking
///   the network, so the extension sees it as it would in Chrome.
///
/// The approach is Search's (Office Commun, MIT, ExtensionShims.swift `ExtensionAuth`).
@available(macOS 15.4, *)
@MainActor
enum ExtensionAuth {
    static let bridgeName = "browsa.identity"

    /// The Chrome Web Store id a chromiumapp.org redirect belongs to, if `url` is one.
    nonisolated static func redirectOwner(_ url: URL?) -> String? {
        guard let url, url.scheme == "https", let host = url.host()?.lowercased(),
              host.hasSuffix(".chromiumapp.org") else { return nil }
        let id = String(host.dropLast(".chromiumapp.org".count))
        return id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil ? id : nil
    }

    private struct Flow {
        let reply: (Any?, (any Error)?) -> Void
        var page: (any EnginePage)?
        var hidden: WKWebView?
        var helper: HiddenNavigator?
    }
    /// One flow at a time per extension, as in Chrome.
    private static var flows: [String: Flow] = [:]

    static func handle(_ body: [String: Any], storeID: String?, host: (any EngineExtensionHost)?,
                       reply: @escaping (Any?, (any Error)?) -> Void) {
        guard let storeID else { return reply(nil, error("Sign-in is only available to Chrome Web Store extensions in Browsa.")) }
        guard let string = body["url"] as? String, let url = URL(string: string), url.scheme == "https" || url.scheme == "http" else {
            return reply(nil, error("Authorization page could not be loaded."))
        }
        if let previous = flows.removeValue(forKey: storeID) { finish(previous, nil, error("Another sign-in started.")) }
        let interactive = body["interactive"] as? Bool ?? false
        if interactive {
            guard let page = host?.openExtensionTab(url: url, windowID: nil, active: true) else {
                return reply(nil, error("Authorization page could not be loaded."))
            }
            flows[storeID] = Flow(reply: reply, page: page)
            // A person may never finish; Chrome gives up when the window closes. Browsa gives up after 10 min.
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
                guard let flow = flows[storeID], flow.page === page else { return }
                flows[storeID] = nil
                finish(flow, nil, error("The user did not approve access."), host: host)
            }
        } else {
            // Quietly, with the tabs' cookies: it ends at the redirect or fails within the timeout.
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: {
                let c = WKWebViewConfiguration()
                c.websiteDataStore = .default()
                return c
            }())
            let navigator = HiddenNavigator()
            view.navigationDelegate = navigator
            flows[storeID] = Flow(reply: reply, hidden: view, helper: navigator)
            view.load(URLRequest(url: url))
            let timeout = min(max((body["timeout"] as? Double ?? 5000) / 1000, 1), 60)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard let flow = flows[storeID], flow.hidden === view else { return }
                flows[storeID] = nil
                finish(flow, nil, error("User interaction required."))
            }
        }
    }

    /// A page is about to go to a chromiumapp.org address. True when Browsa took it: a flow is
    /// waiting (it gets the URL and its tab closes) or the page was given the address with an empty
    /// page for the extension to read.
    static func intercept(_ url: URL, in webView: WKWebView, page: (any EnginePage)?, host: (any EngineExtensionHost)?) -> Bool {
        guard let id = redirectOwner(url) else { return false }
        if let flow = flows[id], (flow.hidden === webView) || (page != nil && flow.page === page) {
            flows[id] = nil
            finish(flow, url.absoluteString, nil, host: host)
            return true
        }
        simulated.insert(url)
        webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<!doctype html><meta charset=utf-8><title>Signing in…</title>")
        return true
    }

    /// Redirect addresses given an empty page: their own load goes ahead.
    private static var simulated: Set<URL> = []
    static func isSimulated(_ url: URL) -> Bool { simulated.remove(url) != nil }

    private static func finish(_ flow: Flow, _ value: Any?, _ failure: (any Error)?, host: (any EngineExtensionHost)? = nil) {
        flow.hidden?.stopLoading()
        flow.hidden?.navigationDelegate = nil
        if let page = flow.page { host?.closeExtensionTab(page) }
        flow.reply(value, failure)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Browsa.Identity", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Watches the hidden view of a quiet flow for the redirect.
    final class HiddenNavigator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url, redirectOwner(url) != nil else { return .allow }
            _ = ExtensionAuth.intercept(url, in: webView, page: nil, host: nil)
            return .cancel
        }
    }
}
#endif
