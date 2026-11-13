import AppKit
import ImageIO
import BrowserEngine

/// Chromium, through the Chromium Embedded Framework (CEF), behind the same `BrowserEngine` API as
/// WebKit. Browsa uses it for call tabs only (Meet, Zoom, Teams): Chromium plays a call's audio and
/// captures the mic itself, with its own echo canceller in between, which WebKit can't offer.
///
/// CEF starts with the first call tab, so Browsa runs no Chromium processes until then.
@MainActor
final class ChromiumEngine: BrowserEngine {
    static let shared = ChromiumEngine()

    private(set) var info = EngineInfo(id: "chromium", name: "Chromium", version: "not started",
                                       capabilities: [.pageZoom, .findInPage, .sessionRestore])
    var downloadsDirectory = URL.downloadsDirectory
    var developerToolsEnabled = false
    private var started = false

    /// Cookies, sign-ins and site data, apart from WebKit's: Application Support/<bundle id>/Chromium.
    static var profileDirectory: URL {
        let id = Bundle.main.bundleIdentifier ?? "com.orriginal.browsa"
        return URL.applicationSupportDirectory.appending(path: id).appending(path: "Chromium")
    }

    private func startIfNeeded() {
        guard !started else { return }
        try? FileManager.default.createDirectory(at: Self.profileDirectory, withIntermediateDirectories: true)
        started = BCEFRuntime.start(withCachePath: Self.profileDirectory.path())
        info = EngineInfo(id: "chromium", name: "Chromium",
                          version: started ? "CEF \(BCEFRuntime.version())" : "failed to start", capabilities: info.capabilities)
    }

    var isRunning: Bool { started }

    func makePage(options: PageOptions, delegate: any EnginePageDelegate) -> any EnginePage {
        startIfNeeded()
        let page = ChromiumPage(url: options.url, profile: options.profile)
        page.delegate = delegate
        return page
    }

    func applyBlocking(_ configuration: BlockingConfiguration) async {}
    func updateBlockingRules(force: Bool) async throws -> Date? { nil }
    func clearWebsiteData(for profile: BrowsingProfile) async {}
    func resetEphemeralProfile() {}
}

/// One Chromium browser: a call tab's page.
@MainActor
final class ChromiumPage: NSObject, EnginePage, BCEFBrowserDelegate {
    let id = UUID()
    let state = PageState()
    weak var delegate: (any EnginePageDelegate)?
    private let browser: BCEFBrowser
    private let profile: BrowsingProfile
    private var findContinuation: CheckedContinuation<Bool, Never>?
    private var lastFind = ""
    /// Main-frame navigations Browsa should look at before Chromium follows them (leaving the call
    /// site for an ordinary page hands the tab back to WebKit). Set by the app.
    static var navigationGate: ((ChromiumPage, URL, Bool) -> Bool)?

    var view: NSView { browser.view }

    init(url: URL?, profile: BrowsingProfile) {
        self.profile = profile
        browser = BCEFBrowser(url: url?.absoluteString, incognito: profile == .ephemeral)
        super.init()
        browser.delegate = self
        state.url = url
    }

    func load(_ url: URL) { browser.loadURL(url.absoluteString) }

    func loadHTML(_ html: String, baseURL: URL?) {
        let encoded = Data(html.utf8).base64EncodedString()
        browser.loadURL("data:text/html;base64,\(encoded)")
    }

    func reload() { browser.reload() }
    func reloadFromOrigin() { browser.reloadIgnoringCache() }
    func stopLoading() { browser.stopLoading() }
    func goBack() { browser.goBack() }
    func goForward() { browser.goForward() }

    var zoom: Double {
        get { browser.zoomFactor }
        set { browser.zoomFactor = newValue }
    }

    var customUserAgent: String?

    func find(_ text: String, backwards: Bool) async -> Bool {
        guard !text.isEmpty else { clearFind(); return false }
        findContinuation?.resume(returning: false)
        let next = text == lastFind
        lastFind = text
        return await withCheckedContinuation { c in
            findContinuation = c
            browser.find(text, forward: !backwards, findNext: next)
        }
    }

    func clearFind() {
        lastFind = ""
        browser.stopFinding()
    }

    /// CEF keeps no back/forward list Browsa can save: a restored call tab reopens its URL (the tab
    /// keeps it), and nothing Chromium-shaped ever reaches a WebKit page's session restore.
    func sessionState() -> Data? { nil }

    func evaluate(_ body: String, inWorld world: String) async throws -> Any? {
        let json: String? = await withCheckedContinuation { c in
            browser.evaluate("(async () => { \(body) })()") { c.resume(returning: $0) }
        }
        guard let data = json?.data(using: .utf8),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = reply["result"] as? [String: Any] else {
            throw NSError(domain: "ChromiumEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "The page didn't answer"])
        }
        return result["value"]
    }

    func snapshot() async -> CGImage? {
        // The page is drawn by Chromium's GPU process, so AppKit's view caching sees nothing.
        let png: Data? = await withCheckedContinuation { c in browser.captureScreenshot { c.resume(returning: $0) } }
        guard let png, let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func close() { browser.close() }

    // MARK: BCEFBrowserDelegate

    func browserAddressChanged(_ url: String) {
        state.url = URL(string: url)
        state.isSecure = url.hasPrefix("https:")
        delegate?.page(self, didCommit: state.url)
    }

    func browserTitleChanged(_ title: String) { state.title = title }
    func browserProgressChanged(_ progress: Double) { state.progress = progress }

    func browserLoadingChanged(_ loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        state.isLoading = loading
        state.canGoBack = canGoBack
        state.canGoForward = canGoForward
    }

    func browserLoadEnded(_ url: String, status: Int32) {
        guard let u = URL(string: url) else { return }
        delegate?.page(self, didFinish: u, title: state.title)
    }

    func browserLoadFailed(_ url: String, code: Int32, text: String) {
        delegate?.page(self, didFailWith: NSError(domain: "Chromium", code: Int(code),
                                                  userInfo: [NSLocalizedDescriptionKey: text, NSURLErrorFailingURLStringErrorKey: url]))
    }

    /// Links that want a new tab open as ordinary Browsa tabs (WebKit, unless they're call sites too).
    func browserWantsNewTab(_ url: String, foreground: Bool) {
        guard let u = URL(string: url), let delegate else { return }
        let request = NavigationRequest(url: u, kind: .link, isMainFrame: true, method: "GET",
                                        wantsNewTab: true, wantsForeground: foreground)
        Task { _ = await delegate.page(self, decide: request) }
    }

    func browserShouldNavigate(_ url: String, userGesture: Bool) -> Bool {
        guard let u = URL(string: url), let gate = Self.navigationGate else { return true }
        return gate(self, u, userGesture)
    }

    func browserFindResult(_ count: Int32, active: Int32, final: Bool) {
        guard final else { return }
        findContinuation?.resume(returning: count > 0)
        findContinuation = nil
    }

    func browserDidClose() {}

    func browserRequestsMedia(_ origin: String, audio: Bool, video: Bool, screen: Bool, decide: @escaping (Bool) -> Void) {
        let host = URL(string: origin)?.host() ?? origin
        guard let delegate else { decide(false); return }
        if screen {
            // CEF has no source picker: a yes shares the entire screen (macOS asks once for Screen
            // Recording). Asked every time.
            Task { decide(await delegate.page(self, requestPermission: .screen, host: host)) }
            return
        }
        let kind: EnginePermission = audio && video ? .cameraAndMicrophone : video ? .camera : .microphone
        Task { decide(await delegate.page(self, requestPermission: kind, host: host)) }
    }

    func browserRequestsNotifications(_ origin: String, decide: @escaping (Bool) -> Void) {
        let host = URL(string: origin)?.host() ?? origin
        guard let delegate else { decide(false); return }
        Task { decide(await delegate.page(self, requestPermission: .notifications, host: host)) }
    }
}
