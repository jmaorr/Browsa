#if os(iOS)
import Foundation
import UIKit
import WebKit
import Suggest

/// Owns one live WKWebView for one Tab, and mirrors its state back onto the Tab model.
@MainActor
public final class TabSession: NSObject {
    public let tab: BrowserTab
    public let webView: WKWebView
    private var observations: [NSKeyValueObservation] = []
    private weak var browser: BrowserState?
    /// Set when the user navigates from the address bar so history records a "typed" visit.
    var pendingVisitSource: Frecency.VisitSource?
    private var chromeTracker = ScrollChromeTracker()

    /// - Parameter loadInitial: false for popups, where WebKit itself loads the request into
    ///   the web view we return from `createWebViewWith`.
    init(tab: BrowserTab, configuration: WKWebViewConfiguration, browser: BrowserState, loadInitial: Bool = true) {
        self.tab = tab
        self.browser = browser
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        // Off on purpose: the leading-edge swipe belongs to the tab strip (scrub through tabs),
        // and accidental "back" swipes were a pain. Back lives on the toolbar button instead.
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = true
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        // Cmd-F and the command bar's "Find on Page" use the system find bar (as Safari does).
        webView.isFindInteractionEnabled = true
        // Pull to refresh, with the system control.
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pulledToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

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
            // Scroll direction drives the compact chrome. One Bool flips with hysteresis, and
            // SwiftUI animates between two fixed layouts. No geometry readers.
            webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                MainActor.assumeIsolated { self?.scrollChanged(sv) }
            },
        ]
    }

    private func scrollChanged(_ sv: UIScrollView) {
        let changed = chromeTracker.update(offsetY: sv.contentOffset.y,
                                           contentHeight: sv.contentSize.height,
                                           viewportHeight: sv.bounds.height,
                                           topInset: sv.adjustedContentInset.top)
        if changed { tab.isChromeCompact = chromeTracker.isCompact }
    }

    @objc private func pulledToRefresh(_ sender: UIRefreshControl) {
        if webView.url == nil { sender.endRefreshing(); return }
        webView.reload()
    }

    private func endRefreshing() {
        if webView.scrollView.refreshControl?.isRefreshing == true {
            webView.scrollView.refreshControl?.endRefreshing()
        }
    }

    /// Tapping the compact pill brings the full bar back.
    public func expandChrome() {
        chromeTracker.expand()
        tab.isChromeCompact = false
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
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        expandChrome()   // new page: show the full bar
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        endRefreshing()
        guard let url = webView.url, !tab.isPrivate else { return }
        let source = pendingVisitSource ?? .link
        pendingVisitSource = nil
        let title = webView.title ?? ""
        if let history = browser?.history {
            Task { await history.recordVisit(url: url, title: title, source: source) }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        endRefreshing()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        endRefreshing()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS kills background web content under memory pressure. Reload quietly.
        webView.reload()
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.shouldPerformDownload { return .download }
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if ["http", "https", "about", "blob", "data", "file"].contains(scheme) { return .allow }
        // tel:, mailto:, App Store links, universal app schemes -> hand to the system.
        _ = await UIApplication.shared.open(url)
        return .cancel
    }

    /// Anything WebKit can't render inline (zips, dmgs, Content-Disposition: attachment) becomes a download.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        browser?.downloads.adopt(download)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        browser?.downloads.adopt(download)
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
