#if os(macOS)
import AppKit
import WebKit
import OSLog
import BrowserEngine
import BrowserCore

let engineLog = Logger(subsystem: "com.orriginal.browsa", category: "webkit")

/// The WebKit engine: every page is a WKWebView, the same engine Safari uses.
///
/// Blocking uses BrowserCore's AdGuard-derived content rule lists and DuckDuckGo's autoconsent,
/// exactly like the iOS app.
@MainActor
public final class WebKitEngine: BrowserEngine {
    public let info: EngineInfo
    public var downloadsDirectory: URL
    public var developerToolsEnabled = false {
        didSet {
            for c in [standardConfiguration, ephemeralConfiguration] { Self.setDeveloperExtras(developerToolsEnabled, on: c) }
            for page in livePages.values.compactMap(\.page) {
                Self.setDeveloperExtras(developerToolsEnabled, on: page.webView.configuration)
            }
        }
    }

    /// WebKit only offers Inspect Element in the context menu with this preference on. It has no
    /// public setter; Safari's Develop menu can inspect Browsa's pages either way (`isInspectable`).
    private static func setDeveloperExtras(_ on: Bool, on configuration: WKWebViewConfiguration) {
        configuration.preferences.setValue(on, forKey: "developerExtrasEnabled")
    }

    private let standardConfiguration: WKWebViewConfiguration
    private var ephemeralConfiguration: WKWebViewConfiguration
    /// For pages the app renders (Reader): no storage, no JavaScript, no rules or scripts.
    private let staticConfiguration: WKWebViewConfiguration
    private var ruleLists: [WKContentRuleList] = []
    private var blocking = BlockingConfiguration(isEnabled: false, ruleGroups: [], allowlist: [], declineCookieBanners: false)
    private var boosts: [PageBoost] = []
    /// Pages that are alive, to reach their content controllers and map script messages back.
    private var livePages: [ObjectIdentifier: WeakPage] = [:]
    private var rulesReady = false
    private var waitingForRules: [() -> Void] = []
    let downloads = DownloadBridge()
    /// `WebKitExtensions` on macOS 15.4 and later. Typed loosely: stored properties can't be gated by OS version.
    private let extensionSupport: AnyObject?
    @available(macOS 15.4, *)
    var webExtensions: WebKitExtensions? { extensionSupport as? WebKitExtensions }
    #if DEBUG
    /// Debug checks: each loaded extension's id, name, popup page and manifest.
    public func debugExtensionPopups() -> [(id: String, name: String, popup: URL?, manifest: [String: Any], errors: [String])] {
        if #available(macOS 15.4, *) { return webExtensions?.debugPopups() ?? [] }
        return []
    }
    #endif

    public init(downloadsDirectory: URL = URL.downloadsDirectory) {
        self.downloadsDirectory = downloadsDirectory
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var caps: EngineCapabilities = [.contentBlocking, .isolatedScripts, .sessionRestore, .pageZoom, .findInPage, .developerTools]
        // WebKit only runs passkeys for apps Apple has granted the web browser entitlement.
        if Bundle.main.object(forInfoDictionaryKey: "BrowsaHasBrowserEntitlement") as? Bool == true { caps.insert(.passkeys) }
        standardConfiguration = Self.makeConfiguration(store: .default())
        ephemeralConfiguration = Self.makeConfiguration(store: .nonPersistent())
        // Extensions only reach web views made from a configuration that already has the controller.
        if #available(macOS 15.4, *) {
            let ext = WebKitExtensions()
            standardConfiguration.webExtensionController = ext.controller
            ephemeralConfiguration.webExtensionController = ext.controller
            extensionSupport = ext
            caps.insert(.webExtensions)
        } else {
            extensionSupport = nil
        }
        info = EngineInfo(id: "webkit", name: "WebKit", version: "macOS \(os.majorVersion).\(os.minorVersion)", capabilities: caps)
        staticConfiguration = Self.makeConfiguration(store: .nonPersistent())
        staticConfiguration.defaultWebpagePreferences.allowsContentJavaScript = false
        downloads.engine = self
    }

    static func makeConfiguration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = store
        c.upgradeKnownHostsToHTTPS = true
        c.mediaTypesRequiringUserActionForPlayback = .all
        c.defaultWebpagePreferences.preferredContentMode = .desktop
        // Sites' own fullscreen buttons (YouTube, Netflix) work on the Mac.
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.isTextInteractionEnabled = true
        c.allowsAirPlayForMediaPlayback = true
        // WKWebView's default user agent leaves out Safari's "Version/… Safari/…" tokens, and some
        // sites then serve older pages or call the browser unsupported.
        c.applicationNameForUserAgent = SafariUserAgent.applicationName
        return c
    }

    // MARK: Pages

    public func makePage(options: PageOptions, delegate: any EnginePageDelegate) -> any EnginePage {
        if !options.allowsJavaScript {
            let page = WebKitPage(configuration: staticConfiguration, engine: self, profile: .ephemeral)
            page.delegate = delegate
            if let url = options.url { page.load(url) }
            return page
        }
        var configuration = options.profile == .ephemeral ? ephemeralConfiguration : standardConfiguration
        if #available(macOS 15.4, *), let url = options.url, let own = webExtensions?.configuration(for: url) {
            configuration = own
        }
        let page = WebKitPage(configuration: configuration, engine: self, profile: options.profile)
        page.delegate = delegate
        register(page)
        if options.sessionState != nil || options.url != nil {
            afterRules { [weak page] in
                guard let page else { return }
                if let state = options.sessionState {
                    page.restore(state, fallback: options.url)
                } else if let url = options.url {
                    page.load(url)
                }
            }
        }
        return page
    }

    /// A popup WebKit asked for. It must be built from WebKit's own configuration.
    func makePopup(configuration: WKWebViewConfiguration, opener: WebKitPage) -> WebKitPage {
        let page = WebKitPage(configuration: configuration, engine: self, profile: opener.profile)
        register(page)
        return page
    }

    func register(_ page: WebKitPage) {
        livePages[ObjectIdentifier(page.webView)] = WeakPage(page: page)
        livePages = livePages.filter { $0.value.page != nil }
        // A popup can bring its own content controller; give it the current rules and scripts.
        install(on: page.webView.configuration.userContentController)
        if #available(macOS 15.4, *) { webExtensions?.pageOpened(page) }
    }

    func unregister(_ page: WebKitPage) {
        livePages[ObjectIdentifier(page.webView)] = nil
        if #available(macOS 15.4, *) { webExtensions?.pageClosed(page) }
    }

    func extensionPageChanged(_ page: WebKitPage) {
        if #available(macOS 15.4, *) { webExtensions?.pageChanged(page) }
    }

    // MARK: Extensions

    public var extensions: [EngineExtension] {
        if #available(macOS 15.4, *) { return webExtensions?.loaded ?? [] }
        return []
    }

    public var extensionHost: (any EngineExtensionHost)? {
        get {
            if #available(macOS 15.4, *) { return webExtensions?.host }
            return nil
        }
        set {
            if #available(macOS 15.4, *) { webExtensions?.host = newValue }
        }
    }

    public func loadInstalledExtensions() async -> [String] {
        await loadInstalledExtensions(folders: [], includeApps: true)
    }

    public func loadInstalledExtensions(folders: [ExtensionFolder], includeApps: Bool) async -> [String] {
        guard #available(macOS 15.4, *), let ext = webExtensions else { return ["needs macOS 15.4"] }
        return await ext.loadInstalled(folders: folders, includeApps: includeApps)
    }

    public func unloadExtensions() {
        if #available(macOS 15.4, *) { webExtensions?.unloadAll() }
    }

    public func performAction(extensionID: String, for page: (any EnginePage)?, anchor: NSView?) {
        if #available(macOS 15.4, *) { webExtensions?.performAction(extensionID: extensionID, for: page as? WebKitPage, anchor: anchor) }
    }

    public func extensionActionState(extensionID: String, for page: (any EnginePage)?) -> EngineActionState? {
        if #available(macOS 15.4, *) { return webExtensions?.actionState(extensionID: extensionID, for: page as? WebKitPage) }
        return nil
    }

    public func pageDidBecomeActive(_ page: any EnginePage) {
        guard #available(macOS 15.4, *), let page = page as? WebKitPage else { return }
        webExtensions?.pageActivated(page)
    }

    func page(for webView: WKWebView) -> WebKitPage? { livePages[ObjectIdentifier(webView)]?.page }

    // MARK: Blocking

    public func applyBlocking(_ configuration: BlockingConfiguration) async {
        blocking = configuration
        let groups = Set(configuration.ruleGroups.compactMap(FilterGroup.init(rawValue:)))
        ruleLists = configuration.isEnabled
            ? await ContentBlocker.shared.lists(for: groups, allowlist: configuration.allowlist) : []
        guard blocking == configuration else { return }   // a newer call won
        for controller in allContentControllers { install(on: controller) }
        markRulesReady()
    }

    public func updateBlockingRules(force: Bool) async throws -> Date? {
        let blocker = ContentBlocker.shared
        if force || blocker.needsUpdate {
            _ = try await blocker.update(groups: Set(FilterGroup.allCases))
            await applyBlocking(blocking)
        }
        return blocker.metadata.lastUpdated
    }

    /// Rule counts per group from the last download, for Settings.
    public var blockingRuleCount: Int {
        let meta = ContentBlocker.shared.metadata
        return blocking.ruleGroups.reduce(0) { $0 + (meta.ruleCounts[$1] ?? 0) }
    }

    private var allContentControllers: [WKUserContentController] {
        var seen = Set<ObjectIdentifier>()
        return ([standardConfiguration.userContentController, ephemeralConfiguration.userContentController]
            + livePages.values.compactMap { $0.page?.webView.configuration.userContentController })
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func install(on controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        ruleLists.forEach(controller.add)
        controller.removeAllUserScripts()
        controller.removeScriptMessageHandler(forName: CookieBannerHandler.messageName, contentWorld: CookieBannerHandler.world)
        let cookieScripts = blocking.declineCookieBanners ? CookieBannerHandler.scripts(skipping: blocking.allowlist) : []
        if !cookieScripts.isEmpty {
            cookieScripts.forEach(controller.addUserScript)
            let handler = CookieBannerHandler { [weak self] webView in
                guard let page = self?.page(for: webView) else { return }
                page.delegate?.pageDidDeclineCookieBanner(page)
            }
            controller.add(handler, contentWorld: CookieBannerHandler.world, name: CookieBannerHandler.messageName)
        }
        if blocking.globalPrivacyControl {
            controller.addUserScript(WKUserScript(source: Self.globalPrivacyControlScript, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false, in: .page))
        }
        for boost in boosts { Self.boostScripts(boost).forEach(controller.addUserScript) }
    }

    // MARK: Boosts

    public func applyBoosts(_ boosts: [PageBoost]) {
        guard boosts != self.boosts else { return }
        self.boosts = boosts
        for controller in allContentControllers { install(on: controller) }
    }

    /// Two scripts per Boost, both checking the host first: the style goes in as early as the page
    /// has an element to hold it, the script once the document has loaded.
    static func boostScripts(_ boost: PageBoost) -> [WKUserScript] {
        let world = WKContentWorld.world(name: PageBoost.world)
        let host = jsString(boost.host.lowercased())
        let guardHost = "const h = location.hostname.toLowerCase(), H = \(host); if (!(h === H || h.endsWith('.' + H))) return;"
        var scripts: [WKUserScript] = []
        if !boost.css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let source = "(() => { \(guardHost)\n\(PageBoost.applyCSSFunction)\n__browsaBoostCSS(\(jsString(boost.css))); })();"
            scripts.append(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        }
        if !boost.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let source = "(() => { \(guardHost)\n try {\n\(boost.script)\n} catch (e) { console.error('Browsa Boost:', e); } })();"
            scripts.append(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: world))
        }
        return scripts
    }

    /// A Swift string as a JavaScript string literal.
    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// Global Privacy Control: sites that honour it treat the visitor as opted out of the sale or
    /// sharing of their data. Defined on the page's own Navigator so the page's scripts see it.
    private static let globalPrivacyControlScript = """
    (() => {
      try {
        if ('globalPrivacyControl' in Navigator.prototype) return;
        Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', {
          get() { return true }, configurable: true, enumerable: true
        });
      } catch (e) {}
    })();
    """

    /// Restored tabs wait for the rule lists, so they can't load unblocked at launch.
    private func afterRules(_ work: @escaping () -> Void) {
        if rulesReady { work(); return }
        waitingForRules.append(work)
        // A page without blocking beats a blank one if compiling takes long.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.markRulesReady()
        }
    }

    private func markRulesReady() {
        rulesReady = true
        let waiting = waitingForRules
        waitingForRules = []
        waiting.forEach { $0() }
    }

    // MARK: Data

    public func clearWebsiteData(for profile: BrowsingProfile) async {
        let store = profile == .ephemeral ? ephemeralConfiguration.websiteDataStore : standardConfiguration.websiteDataStore
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        if profile == .standard { HTTPCookieStorage.shared.removeCookies(since: .distantPast) }
    }

    public func resetEphemeralProfile() {
        // Web views copy their configuration when made, so the next private page gets a fresh
        // store and keeps the same rules and scripts.
        ephemeralConfiguration.websiteDataStore = .nonPersistent()
    }
}

private struct WeakPage {
    weak var page: WebKitPage?
}

/// User agent tokens that match Safari on this Mac.
enum SafariUserAgent {
    static var applicationName: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(v.majorVersion).\(v.minorVersion) Safari/605.1.15"
    }
}
#endif
