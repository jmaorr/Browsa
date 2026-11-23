#if os(macOS)
import AppKit
import WebKit
import CoreServices
import CryptoKit
import Security
import BrowserEngine

/// One WKWebView, behind the engine-neutral `EnginePage`.
@MainActor
public final class WebKitPage: NSObject, EnginePage {
    public let id = UUID()
    public let state = PageState()
    public weak var delegate: (any EnginePageDelegate)?
    let webView: BrowsaWebView
    let profile: BrowsingProfile
    private(set) weak var engine: WebKitEngine?
    private var observations: [NSKeyValueObservation] = []
    /// Set while a restored session hasn't shown a page yet. WebKit can sit on a restored history
    /// entry forever (reload just retries it), where a fresh load of the same address works.
    private var awaitingRestore = false
    /// The certificate each site ("host:port") last showed this page, so a certificate failure can
    /// say which one was refused. Cleared with each new document.
    private var seenCertificates: [String: String] = [:]

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
            webView.observe(\.cameraCaptureState, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { state.isCapturingMedia = wv.cameraCaptureState == .active || wv.microphoneCaptureState == .active }
            },
            webView.observe(\.microphoneCaptureState, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { state.isCapturingMedia = wv.cameraCaptureState == .active || wv.microphoneCaptureState == .active }
            },
            webView.observe(\.themeColor, options: [.new]) { wv, _ in
                MainActor.assumeIsolated { state.themeColor = wv.themeColor?.cgColor }
            },
            webView.observe(\.cameraCaptureState, options: [.new]) { wv, _ in
                MainActor.assumeIsolated {
                    state.isCapturing = wv.cameraCaptureState != .none || wv.microphoneCaptureState != .none
                    state.camera = CaptureState(wv.cameraCaptureState)
                }
            },
            webView.observe(\.microphoneCaptureState, options: [.new]) { wv, _ in
                MainActor.assumeIsolated {
                    state.isCapturing = wv.cameraCaptureState != .none || wv.microphoneCaptureState != .none
                    state.microphone = CaptureState(wv.microphoneCaptureState)
                }
            },
        ]
    }

    /// What each frame last said about sound and typing, by the frame's own token.
    private var frameActivity: [String: PageActivity.Report] = [:]

    /// A frame's activity script reported in.
    func activityChanged(_ report: PageActivity.Report) {
        frameActivity[report.frame] = report
        updateActivity()
    }

    private func updateActivity() {
        let playing = frameActivity.values.contains { $0.audible }
        let typed = frameActivity.values.contains { $0.typed }
        if state.isPlayingAudio != playing { state.isPlayingAudio = playing }
        if state.hasUnsavedInput != typed { state.hasUnsavedInput = typed }
    }

    // MARK: EnginePage

    public func load(_ url: URL) {
        awaitingRestore = false
        webView.load(URLRequest(url: url))
    }

    public func loadHTML(_ html: String, baseURL: URL?) { webView.loadHTMLString(html, baseURL: baseURL) }

    public func reload() {
        if awaitingRestore, let url = webView.url ?? state.url {
            // The restored entry never loaded: start over with a plain request instead.
            awaitingRestore = false
            webView.stopLoading()
            load(url)
        } else if webView.url != nil { webView.reload() }
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
        let found = (try? await webView.find(text, configuration: config).matchFound) ?? false
        // WebKit marks the match only as a selection, which goes grey while the find field has
        // focus, so it looked like nothing was found. Paint it with a CSS custom highlight too.
        _ = try? await webView.evaluateJavaScript(found ? Self.highlightMatch : Self.clearHighlight,
                                                  contentWorld: .defaultClient)
        return found
    }

    public func findMatches(_ text: String) async -> FindMatches? {
        guard !text.isEmpty,
              let result = try? await webView.callAsyncJavaScript(Self.countMatches, arguments: ["q": text],
                                                                   contentWorld: .defaultClient) as? [Int],
              result.count == 3 else { return nil }
        return FindMatches(current: result[0], total: result[1], capped: result[2] == 1)
    }

    public func clearFind() {
        webView.evaluateJavaScript("window.getSelection().removeAllRanges();" + Self.clearHighlight,
                                   in: nil, in: .defaultClient)
    }

    private static let highlightMatch = """
        (() => {
          const sel = getSelection();
          if (!sel.rangeCount || !window.CSS || !CSS.highlights) return;
          let sheet = document.__browsaFindSheet;
          if (!sheet) {
            sheet = new CSSStyleSheet();
            document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
            document.__browsaFindSheet = sheet;
          }
          // The match is the page's selection, which paints over a highlight, so colour that too
          // while find is open. Separate rules, so one selector a build doesn't know can't drop all.
          const mark = 'background-color: #ffd60a !important; color: #000 !important;';
          sheet.replaceSync('');
          for (const sel of ['::highlight(browsa-find)', '::selection', '::selection:window-inactive']) {
            try { sheet.insertRule(sel + ' { ' + mark + ' }', sheet.cssRules.length); } catch (e) {}
          }
          // The other matches, softer, like Safari and Chrome.
          try { sheet.insertRule('::highlight(browsa-find-all) { background-color: rgba(255, 214, 10, 0.35); }', 0); } catch (e) {}
          CSS.highlights.set('browsa-find', new Highlight(sel.getRangeAt(0).cloneRange()));
        })();
        """
    /// Counts visible matches of `q` (case-insensitive, within single text nodes, up to 1000), marks
    /// them all, and works out which one the selection is on. Returns [current, total, capped].
    private static let countMatches = """
        const needle = q.toLocaleLowerCase();
        const sel = getSelection();
        const cur = sel.rangeCount ? sel.getRangeAt(0) : null;
        const root = document.body || document.documentElement;
        const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE']);
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
          acceptNode(node) {
            const el = node.parentElement;
            if (!el || skip.has(el.tagName) || !el.getClientRects().length) return NodeFilter.FILTER_REJECT;
            return NodeFilter.FILTER_ACCEPT;
          }
        });
        const limit = 1000;
        const ranges = [];
        let current = 0;
        let node;
        while ((node = walker.nextNode()) && ranges.length < limit) {
          const text = node.data.toLocaleLowerCase();
          let i = text.indexOf(needle);
          while (i !== -1 && ranges.length < limit) {
            const r = document.createRange();
            r.setStart(node, i);
            r.setEnd(node, i + needle.length);
            ranges.push(r);
            if (cur && !current && r.compareBoundaryPoints(Range.START_TO_START, cur) === 0) current = ranges.length;
            i = text.indexOf(needle, i + needle.length);
          }
        }
        if (window.CSS && CSS.highlights) CSS.highlights.set('browsa-find-all', new Highlight(...ranges));
        return [current, ranges.length, ranges.length >= limit ? 1 : 0];
        """

    private static let clearHighlight = """
        if (window.CSS && CSS.highlights) { CSS.highlights.delete('browsa-find'); CSS.highlights.delete('browsa-find-all'); }
        if (document.__browsaFindSheet) document.__browsaFindSheet.replaceSync('');
        """

    public func sessionState() -> Data? { webView.interactionState as? Data }

    /// Restoring saved state can come to nothing, so load the URL if the page stays empty.
    /// Restoring saved state can come to nothing, or hang on the restored entry, so if no page has
    /// been committed shortly after, load the address afresh.
    func restore(_ data: Data, fallback: URL?) {
        state.url = fallback
        awaitingRestore = true
        webView.interactionState = data
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.awaitingRestore else { return }
            if self.webView.url == nil, !self.webView.isLoading, let fallback {
                self.awaitingRestore = false
                self.load(fallback)
                return
            }
            // Still loading the restored entry: give it a little longer, then start over.
            try? await Task.sleep(for: .seconds(4))
            guard self.awaitingRestore, let url = self.webView.url ?? fallback else { return }
            self.awaitingRestore = false
            self.webView.stopLoading()
            self.load(url)
        }
    }

    public func evaluate(_ body: String, inWorld world: String) async throws -> Any? {
        // "page" is the page's own world, where its scripts and globals live.
        try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: world == "page" ? .page : .world(name: world))
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
        // Option-click on a web link: offered as a Glance first (before Safari's option-click download).
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.option),
           !navigationAction.modifierFlags.contains(.command), let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https", let delegate {
            let glance = NavigationRequest(url: url, kind: .link, isMainFrame: true, method: "GET", wantsGlance: true)
            if await delegate.page(self, decide: glance) == .cancel { return (.cancel, preferences) }
        }
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
        var newTab = kind == .link && (flags.contains(.command) || navigationAction.buttonNumber == 2)
        // An extension's page (its own web view setup) leaving for the web, e.g. 1Password's Sign In: the
        // web page goes in a normal tab, so it gets Browsa's usual web view.
        let fromExtension = webView.url?.scheme == "webkit-extension" && (navigationAction.targetFrame?.isMainFrame ?? true)
            && (url.scheme == "http" || url.scheme == "https")
        if fromExtension { newTab = true }
        let request = NavigationRequest(url: url, kind: kind,
                                        isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                                        method: navigationAction.request.httpMethod ?? "GET",
                                        wantsNewTab: newTab, wantsForeground: newTab && (flags.contains(.shift) || fromExtension))
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
        awaitingRestore = false
        // A new document: the old one's sound and drafts are gone, and its frames report afresh.
        frameActivity = [:]
        seenCertificates = [:]
        updateActivity()
        delegate?.page(self, didCommit: webView.url)
        engine?.extensionPageChanged(self)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        delegate?.page(self, didFinish: url, title: webView.title ?? "")
        engine?.extensionPageChanged(self)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        report(error)
    }

    // A failure after the page committed leaves the page up, so it isn't reported as an error page.

    private func report(_ error: any Error) {
        var ns = error as NSError
        // Cancelled loads and "frame load interrupted" (a download took over) aren't failures.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && [102, 204].contains(ns.code) { return }
        // A certificate failure carries the certificate that was refused, for "Visit Anyway".
        if ns.domain == NSURLErrorDomain, Self.certificateErrors.contains(ns.code),
           let url = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url, let host = url.host(),
           let fingerprint = seenCertificates[ServerCertificate.site(host: host, port: url.port)] {
            var info = ns.userInfo
            info[ServerCertificate.errorUserInfoKey] = fingerprint
            ns = NSError(domain: ns.domain, code: ns.code, userInfo: info)
        }
        delegate?.page(self, didFailWith: ns)
    }

    private static let certificateErrors: Set<Int> = [
        NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
    ]

    /// Every HTTPS connection asks. Nothing changes unless the app trusts a certificate the system
    /// doesn't: then the site loads as if it were trusted.
    private func serverTrust(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard let trust = space.serverTrust, let delegate, let fingerprint = Self.fingerprint(of: trust) else {
            return (.performDefaultHandling, nil)
        }
        let certificate = ServerCertificate(host: space.host, port: space.port, fingerprint: fingerprint)
        seenCertificates[certificate.site] = fingerprint
        guard delegate.page(self, trusts: certificate) else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }

    /// SHA-256 of the site's own certificate, the first in the chain.
    private static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        engineLog.error("web process terminated: \(webView.url?.host() ?? "no host", privacy: .public)")
        delegate?.pageContentProcessDidTerminate(self)
    }

    public func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust { return serverTrust(challenge) }
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
        let features = PopupFeatures(width: windowFeatures.width?.doubleValue,
                                     height: windowFeatures.height?.doubleValue,
                                     hidesToolbars: windowFeatures.toolbarsVisibility?.boolValue == false)
        guard let popupDelegate = delegate.page(self, openedPopup: popup, url: navigationAction.request.url,
                                                features: features) else {
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

    public func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                        initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        // tools/audio-bench runs unattended: its local page gets the mic without asking (test builds only).
        if AudioBench.isEnabled {
            FileHandle.standardError.write(Data("AudioBench: media capture asked by \(origin.host), type \(type.rawValue)\n".utf8))
            if type == .microphone, ["localhost", "127.0.0.1"].contains(origin.host) { return .grant }
        }
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

/// Items the app adds to a page's right-click menu (Add Note, say). Given the web view and the
/// click point in it, top-left origin, in CSS pixels at zoom 1.
@MainActor
public enum PageMenuItems {
    public static var provider: ((NSView, CGPoint) -> [NSMenuItem])?
}

/// WKWebView with Browsa's link menu wording: windows are tabs here.
final class BrowsaWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        var p = convert(event.locationInWindow, from: nil)
        if !isFlipped { p.y = bounds.height - p.y }
        p = CGPoint(x: p.x / pageZoom, y: p.y / pageZoom)
        if let items = PageMenuItems.provider?(self, p), !items.isEmpty {
            menu.insertItem(.separator(), at: 0)
            for item in items.reversed() { menu.insertItem(item, at: 0) }
        }
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
    /// The page each download started from, for its quarantine record.
    private var origins: [ObjectIdentifier: URL] = [:]
    /// Names asked for up front (an extension's chrome.downloads.download({ filename })).
    private var requestedNames: [ObjectIdentifier: String] = [:]

    func adopt(_ download: WKDownload, from page: WebKitPage, filename: String? = nil) {
        download.delegate = self
        if let filename, !filename.isEmpty { requestedNames[ObjectIdentifier(download)] = filename }
        let source = download.originalRequest?.url
        origins[ObjectIdentifier(download)] = page.webView.url
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
        // "folder/name.png" from an extension: just the name; folders inside Downloads aren't made.
        let asked = requestedNames.removeValue(forKey: ObjectIdentifier(download))
            .map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let dest = Self.uniqueDestination(for: asked ?? suggestedFilename, in: dir)
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
        if let url = items[key]?.fileURL {
            Self.quarantine(url, source: items[key]?.sourceURL, origin: origins[key])
        }
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
        origins[key] = nil
    }

    /// Marks a finished download as coming from the internet, so Gatekeeper checks an app or
    /// installer before it first opens, as it does for Safari's downloads. Browsa isn't sandboxed,
    /// so macOS doesn't do this for it. A file that already carries the mark keeps it.
    nonisolated static func quarantine(_ file: URL, source: URL?, origin: URL?) {
        var url = file
        if let existing = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]), existing.quarantineProperties != nil { return }
        var props: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Browsa",
            kLSQuarantineAgentBundleIdentifierKey as String: Bundle.main.bundleIdentifier ?? "com.orriginal.browsa",
            kLSQuarantineTimeStampKey as String: Date(),
        ]
        // Only real web addresses are recorded: a data: or blob: URL can be huge and says nothing.
        if let source, ["http", "https"].contains(source.scheme?.lowercased() ?? "") { props[kLSQuarantineDataURLKey as String] = source }
        if let origin, ["http", "https"].contains(origin.scheme?.lowercased() ?? "") { props[kLSQuarantineOriginURLKey as String] = origin }
        var values = URLResourceValues()
        values.quarantineProperties = props
        do { try url.setResourceValues(values) } catch { print("Couldn't quarantine \(file.lastPathComponent): \(error)") }
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

private extension CaptureState {
    init(_ state: WKMediaCaptureState) {
        switch state {
        case .active: self = .on
        case .muted: self = .muted
        default: self = .off
        }
    }
}
