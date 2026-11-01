#if os(iOS)
import Foundation
import UIKit
import WebKit
import Suggest

/// Owns one live WKWebView for one Tab, and mirrors its state back onto the Tab model.
@MainActor
public final class TabSession: NSObject {
    public let tab: Tab
    public let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    private weak var browser: BrowserState?
    /// Set when the user navigates from the address bar so history records a "typed" visit.
    var pendingVisitSource: Frecency.VisitSource?

    /// - Parameter loadInitial: false for popups, where WebKit itself loads the request into
    ///   the web view we return from `createWebViewWith`.
    init(tab: Tab, configuration: WKWebViewConfiguration, browser: BrowserState, loadInitial: Bool = true) {
        self.tab = tab
        self.browser = browser
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic

        observe()

        if !loadInitial {
            // WebKit drives the first load.
        } else if let state = tab.interactionState {
            webView.interactionState = state
        } else if let url = tab.url {
            webView.load(URLRequest(url: url))
        }
    }

    private func observe() {
        let tab = self.tab
        observations = [
            webView.observe(\.url, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { if let u = wv.url { tab.url = u } }
            },
            webView.observe(\.title, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { tab.title = wv.title ?? "" }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { tab.estimatedProgress = wv.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { tab.isLoading = wv.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { tab.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { tab.canGoForward = wv.canGoForward }
            },
        ]
    }

    public func load(_ url: URL, source: Frecency.VisitSource = .typed) {
        pendingVisitSource = source
        webView.load(URLRequest(url: url))
    }

    /// Captures state so the web view can be torn down and rebuilt later.
    func freeze() {
        tab.interactionState = webView.interactionState as? Data
    }
}

extension TabSession: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url, !tab.isPrivate else { return }
        let source = pendingVisitSource ?? .link
        pendingVisitSource = nil
        let title = webView.title ?? ""
        if let history = browser?.history {
            Task { await history.recordVisit(url: url, title: title, source: source) }
        }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS kills background web content under memory pressure. Reload quietly.
        webView.reload()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if ["http", "https", "about", "blob", "data", "file"].contains(scheme) { return .allow }
        // tel:, mailto:, App Store links, universal app schemes -> hand to the system.
        _ = await UIApplication.shared.open(url)
        return .cancel
    }
}

extension TabSession: WKUIDelegate {
    /// target=_blank and window.open -> new tab in the same space.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let browser, let url = navigationAction.request.url else { return nil }
        // Returning the new web view (built from `configuration`) keeps window.opener working.
        return browser.openPopup(url: url, configuration: configuration, from: tab)
    }

    public func webViewDidClose(_ webView: WKWebView) {
        browser?.close(tab)
    }
}
#endif
