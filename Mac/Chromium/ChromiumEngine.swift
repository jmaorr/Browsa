import AppKit
import ImageIO
import BrowserEngine

/// Chromium, through the Chromium Embedded Framework (CEF), behind the same `BrowserEngine` API as
/// WebKit. Spike: pages, navigation, zoom, find and new tabs work; blocking, isolated scripts,
/// session restore and downloads don't yet.
@MainActor
final class ChromiumEngine: BrowserEngine {
    let info: EngineInfo
    var downloadsDirectory = URL.downloadsDirectory
    var developerToolsEnabled = false

    init() {
        let cache = URL.applicationSupportDirectory.appending(path: "Browsa Chromium/CEF")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let started = BCEFRuntime.start(withCachePath: cache.path())
        info = EngineInfo(id: "chromium", name: "Chromium",
                          version: started ? "CEF \(BCEFRuntime.version())" : "failed to start",
                          capabilities: [.pageZoom, .findInPage])
    }

    func makePage(options: PageOptions, delegate: any EnginePageDelegate) -> any EnginePage {
        let page = ChromiumPage(url: options.url, profile: options.profile)
        page.delegate = delegate
        return page
    }

    func applyBlocking(_ configuration: BlockingConfiguration) async {}
    func updateBlockingRules(force: Bool) async throws -> Date? { nil }
    func clearWebsiteData(for profile: BrowsingProfile) async {}
    func resetEphemeralProfile() {}
}

/// One Chromium browser.
@MainActor
final class ChromiumPage: NSObject, EnginePage, BCEFBrowserDelegate {
    let id = UUID()
    let state = PageState()
    weak var delegate: (any EnginePageDelegate)?
    private let browser: BCEFBrowser
    private let profile: BrowsingProfile
    private var findContinuation: CheckedContinuation<Bool, Never>?
    private var lastFind = ""

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

    /// CEF has no saved back/forward list like WebKit's; keep the URL.
    func sessionState() -> Data? { state.url.flatMap { try? JSONEncoder().encode(["url": $0.absoluteString]) } }

    func evaluate(_ body: String, inWorld world: String) async throws -> Any? {
        throw NSError(domain: "ChromiumEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Isolated scripts aren't supported yet"])
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

    func browserWantsNewTab(_ url: String, foreground: Bool) {
        let popup = ChromiumPage(url: URL(string: url), profile: profile)
        popup.delegate = delegate?.page(self, openedPopup: popup, url: URL(string: url))
        if popup.delegate == nil { popup.close() }
    }

    func browserShouldNavigate(_ url: String, userGesture: Bool) -> Bool { true }

    func browserFindResult(_ count: Int32, active: Int32, final: Bool) {
        guard final else { return }
        findContinuation?.resume(returning: count > 0)
        findContinuation = nil
    }

    func browserDidClose() {}
}
