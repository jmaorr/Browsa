#if os(macOS)
import AppKit
import WebKit
import BrowserEngine

/// One WKWebView, behind the engine-neutral `EnginePage`.
@MainActor
public final class WebKitPage: NSObject, EnginePage {
    public let id = UUID()
    public let state = PageState()
    public weak var delegate: (any EnginePageDelegate)?
    let webView: BrowsaWebView
    let profile: BrowsingProfile
    private weak var engine: WebKitEngine?
    private var observations: [NSKeyValueObservation] = []

    public var view: NSView { webView }

    init(configuration: WKWebViewConfiguration, engine: WebKitEngine, profile: BrowsingProfile) {
        self.engine = engine
        self.profile = profile
        webView = BrowsaWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.allowsLinkPreview = true
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        observe()
    }

    private func observe() {
        let state = self.state
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { wv, _ in
                MainActor.assumeIsolated { if let u = wv.url { state.url = u } }
            },
            webView.observe(\.title, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { state.title = wv.title ?? "" }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { state.progress = wv.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { state.isLoading = wv.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { state.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { state.canGoForward = wv.canGoForward }
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { state.isSecure = wv.hasOnlySecureContent }
            },
            webView.observe(\.themeColor, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { state.themeColor = wv.themeColor?.cgColor }
            },
        ]
    }

    // MARK: EnginePage

    public func load(_ url: URL) { webView.load(URLRequest(url: url)) }

    public func loadHTML(_ html: String, baseURL: URL?) { webView.loadHTMLString(html, baseURL: baseURL) }

    public func reload() {
        if webView.url != nil { webView.reload() }
        else if let url = state.url { load(url) }
    }

    public func reloadFromOrigin() { webView.reloadFromOrigin() }
    public func stopLoading() { webView.stopLoading() }
    public func goBack() { webView.goBack() }
    public func goForward() { webView.goForward() }

    public var zoom: Double {
        get { webView.pageZoom }
        set { webView.pageZoom = newValue }
    }

    public var customUserAgent: String? {
        get { webView.customUserAgent }
        set { if webView.customUserAgent != newValue { webView.customUserAgent = newValue } }
    }

    public func find(_ text: String, backwards: Bool) async -> Bool {
        guard !text.isEmpty else { clearFind(); return false }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        return (try? await webView.find(text, configuration: config).matchFound) ?? false
    }

    public func clearFind() {
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
    }

    public func sessionState() -> Data? { webView.interactionState as? Data }

    /// Restoring saved state can come to nothing, so load the URL if the page stays empty.
    func restore(_ data: Data, fallback: URL?) {
        state.url = fallback
        webView.interactionState = data
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.webView.url == nil, !self.webView.isLoading, let fallback else { return }
            self.load(fallback)
        }
    }

    public func evaluate(_ body: String, inWorld world: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .world(name: world))
    }

    public func snapshot() async -> CGImage? {
        guard webView.window != nil else { return nil }
        let image = try? await webView.takeSnapshot(configuration: nil)
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    public func close() {
        webView.stopLoading()
        observations = []
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        engine?.unregister(self)
    }

    private func host(of frame: WKFrameInfo) -> String {
        let h = frame.securityOrigin.host
        return h.isEmpty ? (webView.url?.host() ?? "This page") : h
    }
}

// MARK: - Navigation

extension WebKitPage: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        if navigationAction.shouldPerformDownload { return (.download, preferences) }
        guard let url = navigationAction.request.url else { return (.allow, preferences) }
        let kind: NavigationRequest.Kind = switch navigationAction.navigationType {
        case .linkActivated: .link
        case .formSubmitted, .formResubmitted: .formSubmit
        case .backForward: .backForward
        case .reload: .reload
        default: .other
        }
        let flags = navigationAction.modifierFlags
        let newTab = kind == .link && (flags.contains(.command) || navigationAction.buttonNumber == 2)
        let request = NavigationRequest(url: url, kind: kind,
                                        isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                                        method: navigationAction.request.httpMethod ?? "GET",
                                        wantsNewTab: newTab, wantsForeground: newTab && flags.contains(.shift))
        guard let delegate else { return (.allow, preferences) }
        switch await delegate.page(self, decide: request) {
        case .allow:
            return (.allow, preferences)
        case .cancel:
            return (.cancel, preferences)
        case .download:
            return (.download, preferences)
        case .redirect(let target):
            var r = navigationAction.request
            r.url = target
            webView.load(r)
            return (.cancel, preferences)
        case .allowWith(let desktop, let ua):
            preferences.preferredContentMode = desktop ? .desktop : .mobile
            customUserAgent = ua
            return (.allow, preferences)
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        delegate?.page(self, didCommit: webView.url)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        delegate?.page(self, didFinish: url, title: webView.title ?? "")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        report(error)
    }

    // A failure after the page committed leaves the page up, so it isn't reported as an error page.

    private func report(_ error: any Error) {
        let ns = error as NSError
        // Cancelled loads and "frame load interrupted" (a download took over) aren't failures.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && [102, 204].contains(ns.code) { return }
        delegate?.page(self, didFailWith: ns)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        engineLog.error("web process terminated: \(webView.url?.host() ?? "no host", privacy: .public)")
        delegate?.pageContentProcessDidTerminate(self)
    }

    public func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(method),
              let delegate else { return (.performDefaultHandling, nil) }
        guard challenge.previousFailureCount < 3 else { return (.cancelAuthenticationChallenge, nil) }
        let answer = await delegate.page(self, show: .credentials(host: challenge.protectionSpace.host,
                                                                  realm: challenge.protectionSpace.realm))
        guard case .credentials(let user, let password) = answer else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        engine?.downloads.adopt(download, from: self)
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        engine?.downloads.adopt(download, from: self)
    }
}

// MARK: - UI

extension WebKitPage: WKUIDelegate {
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let engine, let delegate else { return nil }
        let popup = engine.makePopup(configuration: configuration, opener: self)
        guard let popupDelegate = delegate.page(self, openedPopup: popup, url: navigationAction.request.url) else {
            popup.close()
            return nil
        }
        popup.delegate = popupDelegate
        return popup.webView
    }

    public func webViewDidClose(_ webView: WKWebView) {
        delegate?.pageDidRequestClose(self)
    }

    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async {
        _ = await delegate?.page(self, show: .alert(host: host(of: frame), message: message))
    }

    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                        initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await delegate?.page(self, show: .confirm(host: host(of: frame), message: message)) == .ok
    }

    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                        defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let answer = await delegate?.page(self, show: .prompt(host: host(of: frame), message: prompt, defaultText: defaultText ?? ""))
        if case .text(let t) = answer { return t }
        return nil
    }

    public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        guard let delegate else { return .deny }
        let kind: EnginePermission = switch type {
        case .camera: .camera
        case .microphone: .microphone
        default: .cameraAndMicrophone
        }
        return await delegate.page(self, requestPermission: kind, host: origin.host) ? .grant : .deny
    }

    public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                        initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        await delegate?.page(self, chooseFiles: FileChooserRequest(allowsMultiple: parameters.allowsMultipleSelection,
                                                                   allowsDirectories: parameters.allowsDirectories))
    }
}

/// WKWebView with Browsa's link menu wording: windows are tabs here.
final class BrowsaWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow": item.title = "Open Link in New Tab"
            case "WKMenuItemIdentifierOpenImageInNewWindow": item.title = "Open Image in New Tab"
            case "WKMenuItemIdentifierOpenMediaInNewWindow": item.title = "Open Video in New Tab"
            case "WKMenuItemIdentifierOpenFrameInNewWindow": item.title = "Open Frame in New Tab"
            default: break
            }
        }
    }
}

// MARK: - Downloads

/// Saves WKDownloads into the engine's downloads folder and mirrors them onto `EngineDownload`s.
@MainActor
final class DownloadBridge: NSObject, WKDownloadDelegate {
    weak var engine: WebKitEngine?
    private var items: [ObjectIdentifier: EngineDownload] = [:]
    private var progress: [ObjectIdentifier: NSKeyValueObservation] = [:]

    func adopt(_ download: WKDownload, from page: WebKitPage) {
        download.delegate = self
        let source = download.originalRequest?.url
        let item = EngineDownload(filename: source?.lastPathComponent ?? "Download", sourceURL: source)
        item.cancelHandler = { [weak download] in download?.cancel { _ in } }
        let key = ObjectIdentifier(download)
        items[key] = item
        progress[key] = download.progress.observe(\.fractionCompleted) { p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in item.progress = f }
        }
        page.delegate?.page(page, didStartDownload: item)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        let dir = engine?.downloadsDirectory ?? URL.downloadsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = Self.uniqueDestination(for: suggestedFilename, in: dir)
        if let item = items[ObjectIdentifier(download)] {
            item.filename = dest.lastPathComponent
            item.fileURL = dest
        }
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        items[key]?.progress = 1
        items[key]?.status = .finished
        // Bounce the Downloads stack in the Dock, like Safari.
        if let url = items[key]?.fileURL {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: url.path)
        }
        finish(key)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        if items[key]?.status == .running { items[key]?.status = .failed(error.localizedDescription) }
        finish(key)
    }

    private func finish(_ key: ObjectIdentifier) {
        progress[key] = nil
        items[key] = nil
    }

    /// "report.pdf" becomes "report 2.pdf" if taken.
    nonisolated static func uniqueDestination(for filename: String, in dir: URL) -> URL {
        let fm = FileManager.default
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = dir.appending(path: filename)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
#endif
