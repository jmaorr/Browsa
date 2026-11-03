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
    /// iOS killed the web process while this tab was out of sight. Reload when it's next shown.
    private var needsRecovery = false
    private var lastTermination: Date?

    /// - Parameter loadInitial: false for popups, where WebKit itself loads the request into
    ///   the web view we return from `createWebViewWith`.
    init(tab: BrowserTab, configuration: WKWebViewConfiguration, browser: BrowserState, loadInitial: Bool = true) {
        self.tab = tab
        self.browser = browser
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        // The edges belong to back and forward. The tab strip starts from the tabs button.
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isInspectable = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // The layouts set the insets themselves, so the page reaches the top edge instead of
        // sitting under a blank safe-area band.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        // Cmd-F and the command bar's "Find on Page" use the system find bar (as Safari does).
        webView.isFindInteractionEnabled = true
        // Pull to refresh, with the system control.
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pulledToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        observe()

        if !loadInitial {
            // WebKit drives the first load.
        } else if tab.interactionState != nil || tab.url != nil {
            showLastPictureUntilPainted()
            browser.pool.afterContentRules { [weak self] in
                guard let self else { return }
                if let state = tab.interactionState {
                    webView.interactionState = state
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        self?.loadIfRestoreStalled()
                    }
                } else if let url = tab.url {
                    webView.load(URLRequest(url: url))
                }
            }
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
                MainActor.assumeIsolated {
                    tab.estimatedProgress = wv.estimatedProgress
                    if wv.estimatedProgress > 0.6 { tab.isAwaitingFirstPaint = false }
                }
            },
            webView.observe(\.isLoading, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { tab.isLoading = wv.isLoading }
            },
            webView.observe(\.underPageBackgroundColor, options: [.initial, .new]) { wv, _ in
                MainActor.assumeIsolated { tab.pageBackground = wv.underPageBackgroundColor.cgColor }
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
        if webView.url == nil && tab.url == nil { sender.endRefreshing(); return }
        reloadOrLoad()
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

    /// Covers the blank web view with the tab's last picture while it loads. The time limit is for
    /// a restore that never reports back.
    private func showLastPictureUntilPainted() {
        tab.isAwaitingFirstPaint = true
        let tab = self.tab
        Task {
            try? await Task.sleep(for: .seconds(6))
            tab.isAwaitingFirstPaint = false
        }
    }

    /// Called whenever the tab comes on screen.
    func recoverIfNeeded() {
        guard needsRecovery else { return }
        needsRecovery = false
        recover()
    }

    private func recover() {
        webViewLog.notice("recovering by reload: \(self.tab.url?.host() ?? "no host", privacy: .public)")
        showLastPictureUntilPainted()
        reloadOrLoad()
    }

    /// A web view that has no page of its own has nothing for `reload()` to act on, and does nothing.
    func reloadOrLoad() {
        if webView.url != nil {
            webView.reload()
        } else if let url = tab.url {
            webView.load(URLRequest(url: url))
        }
    }

    /// Restoring saved state can come to nothing, leaving the tab showing a URL the web view doesn't have.
    private func loadIfRestoreStalled() {
        guard webView.url == nil, !webView.isLoading, let url = tab.url else { return }
        webViewLog.notice("restore stalled, loading: \(url.host() ?? "no host", privacy: .public)")
        webView.load(URLRequest(url: url))
    }

    /// Captures state so the web view can be torn down and rebuilt later.
    func freeze() {
        tab.interactionState = webView.interactionState as? Data
    }
}

extension TabSession: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab.loadError = nil
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        expandChrome()   // new page: show the full bar
        tab.loadError = nil
        browser?.cancelPrompts(for: tab.id)   // dialogs from the previous page are moot
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        endRefreshing()
        tab.isAwaitingFirstPaint = false
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
        tab.isAwaitingFirstPaint = false
    }

    /// The page never arrived: show our error page instead of a blank screen.
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        endRefreshing()
        tab.isAwaitingFirstPaint = false
        let ns = error as NSError
        guard !LoadError.isIgnorable(ns) else { return }
        let failed = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        tab.loadError = LoadError(url: failed, error: ns)
        expandChrome()
    }

    /// Password-protected pages (HTTP Basic/Digest/NTLM). Certificates use the system's checks.
    public func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(method),
              let browser else { return (.performDefaultHandling, nil) }
        // Three wrong tries in a row: stop asking and let the server's error page show.
        guard challenge.previousFailureCount < 3 else { return (.cancelAuthenticationChallenge, nil) }
        let host = challenge.protectionSpace.host
        let answer = await browser.ask(.credentials(realm: challenge.protectionSpace.realm), host: host,
                                       message: "Sign in to \(host)", from: tab)
        guard case .credentials(let user, let password) = answer else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webViewLog.error("web process terminated: \(self.tab.url?.host() ?? "no host", privacy: .public), in window \(webView.window != nil, privacy: .public), app state \(UIApplication.shared.applicationState.rawValue, privacy: .public)")
        // iOS kills web content under memory pressure. A tab out of sight waits until it's shown,
        // so a low-memory phone isn't reloading every tab at once.
        guard webView.window != nil else {
            needsRecovery = true
            return
        }
        // Dying again straight after a reload is the page itself, and reloading would loop forever.
        let diedRecently = lastTermination.map { Date().timeIntervalSince($0) < 10 } ?? false
        lastTermination = .now
        if diedRecently {
            let error = NSError(domain: "Browsa", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "This page keeps crashing."])
            tab.loadError = LoadError(url: tab.url, error: error)
        } else {
            recover()
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return (.allow, preferences) }
        if ["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            // Tracking parameters come off before the page ever sees them. Only plain GET
            // navigations are rewritten, so form posts and redirects with bodies are untouched.
            if isMainFrame, let browser, browser.settings.cleanLinks,
               navigationAction.request.httpMethod ?? "GET" == "GET",
               !browser.settings.blockingDisabled(for: url.host()),
               let clean = LinkCleaner.clean(url) {
                var request = navigationAction.request
                request.url = clean
                webView.load(request)
                return (.cancel, preferences)
            }
            // Desktop site on the inner display, mobile on the outer (per-site overrides win).
            if isMainFrame, let browser {
                let desktop = browser.prefersDesktop(for: url)
                preferences.preferredContentMode = desktop ? .desktop : .mobile
                // WebKit's desktop UA would still carry the mobile "Safari" tokens, so send
                // Mac Safari's exact string instead.
                let ua = desktop ? SafariUserAgent.desktop : nil
                if webView.customUserAgent != ua { webView.customUserAgent = ua }
                tab.isDesktopSite = desktop
            }
            return (.allow, preferences)
        }
        // tel:, mailto:, App Store links, universal app schemes -> hand to the system.
        _ = await UIApplication.shared.open(url)
        return (.cancel, preferences)
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

    // MARK: JavaScript dialogs

    private func host(of frame: WKFrameInfo) -> String {
        frame.securityOrigin.host.isEmpty ? (webView.url.map(URLNormalizer.displayHost) ?? "This page") : frame.securityOrigin.host
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async {
        _ = await browser?.ask(.alert, host: host(of: frame), message: message, from: tab)
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await browser?.ask(.confirm, host: host(of: frame), message: message, from: tab) == .ok
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                        defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let answer = await browser?.ask(.textInput(defaultText: defaultText ?? ""), host: host(of: frame), message: prompt, from: tab)
        if case .text(let t) = answer { return t }
        return nil
    }

    // MARK: Permissions

    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard let browser else { return .deny }
        let kind: SitePermission = switch type {
        case .camera: .camera
        case .microphone: .microphone
        default: .cameraAndMicrophone
        }
        return await browser.decide(kind, host: origin.host, tab: tab)
    }

    public func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo) async -> WKPermissionDecision {
        guard let browser else { return .deny }
        return await browser.decide(.motion, host: origin.host, tab: tab)
    }

    // MARK: Long-press on links

    public func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo) async
        -> UIContextMenuConfiguration? {
        guard let url = elementInfo.linkURL else {
            // Images and other elements keep WebKit's own menu.
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { UIMenu(children: $0) }
        }
        guard let browser else { return nil }
        // Everything the menu needs is read here, on the main actor, so the menu closures only
        // hop back to it to act (UIKit may call them from a nonisolated context).
        let tab = self.tab
        let isFavorite = browser.isFavorite(url)
        let act: @Sendable (@escaping @MainActor (BrowserState, TabSession?) -> Void) -> UIActionHandler = { body in
            { [weak browser, weak self] _ in Task { @MainActor in if let browser { body(browser, self) } } }
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { suggested in
            let open = UIMenu(options: .displayInline, children: [
                UIAction(title: "Open in New Tab", image: UIImage(systemName: "plus.square.on.square"),
                         handler: act { b, _ in b.newTab(url: url, source: .link) }),
                UIAction(title: "Open in Background", image: UIImage(systemName: "square.stack"),
                         handler: act { b, _ in b.openInBackground(url, from: tab) }),
            ])
            var more: [UIMenuElement] = [
                UIAction(title: "Copy Link", image: UIImage(systemName: "link"), handler: act { b, _ in b.copyToPasteboard(url) }),
                UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up"), handler: act { _, s in s?.share(url) }),
            ]
            if !isFavorite {
                more.append(UIAction(title: "Add to Favourites", image: UIImage(systemName: "star"), handler: act { b, _ in
                    b.addFavorite(url: url, title: URLNormalizer.displayHost(url))
                    b.showToast("Added to Favourites")
                }))
            }
            // Keep WebKit's extras (e.g. Download Linked File, image actions), minus duplicates.
            let ours: Set<String> = ["Open", "Open Link", "Open in New Tab", "Copy Link", "Share…", "Share", "Add to Reading List"]
            let extras = suggested.filter { !ours.contains(($0 as? UIAction)?.title ?? ($0 as? UIMenu)?.title ?? "") }
            return UIMenu(children: [open, UIMenu(options: .displayInline, children: more)]
                          + (extras.isEmpty ? [] : [UIMenu(options: .displayInline, children: extras)]))
        }
    }

    /// Tapping the link preview opens it in this tab, like Safari.
    public func webView(_ webView: WKWebView, contextMenuForElement elementInfo: WKContextMenuElementInfo,
                        willCommitWithAnimator animator: any UIContextMenuInteractionCommitAnimating) {
        guard let url = elementInfo.linkURL else { return }
        animator.addCompletion { [weak self] in self?.load(url, source: .link) }
    }

    private func share(_ url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = webView
        vc.popoverPresentationController?.sourceRect = CGRect(x: webView.bounds.midX, y: webView.bounds.midY, width: 1, height: 1)
        var top = webView.window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        top?.present(vc, animated: true)
    }
}
extension TabSession {
    /// The visible page, drawn at a reduced scale. Returns nil when the web view isn't in a window.
    func renderThumbnail(maxWidth: CGFloat = 420) -> UIImage? {
        guard webView.window != nil, webView.bounds.width > 0 else { return nil }
        let bounds = webView.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(webView.window?.screen.scale ?? 2, maxWidth / bounds.width * 2)
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            webView.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }
}

#endif
