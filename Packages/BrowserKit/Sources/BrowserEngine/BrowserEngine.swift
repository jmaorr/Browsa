import Foundation
import CoreGraphics
import Observation
#if canImport(AppKit)
import AppKit
/// The view an engine draws its page into.
public typealias PlatformView = NSView
#elseif canImport(UIKit)
import UIKit
public typealias PlatformView = UIView
#endif

// MARK: - Engine

/// A web engine the browser can run on.
///
/// The app never talks to WKWebView (or any other engine) directly. It asks the engine for pages,
/// shows each page's `view`, and answers the page's questions through `EnginePageDelegate`. That
/// keeps tabs, spaces, suggestions and every bit of UI engine-neutral, so another engine can be
/// added beside WebKit without touching them. See docs/engines.md.
@MainActor
public protocol BrowserEngine: AnyObject {
    /// Name, version and what this engine can do. The UI hides features an engine doesn't offer.
    var info: EngineInfo { get }

    /// Makes a page. With `options.sessionState`, the page comes back with its back/forward list;
    /// otherwise it loads `options.url`, if there is one.
    func makePage(options: PageOptions, delegate: any EnginePageDelegate) -> any EnginePage

    /// Applies ad, tracker and cookie-banner blocking to every page, now and later.
    func applyBlocking(_ configuration: BlockingConfiguration) async

    /// Fetches newer blocking rules if they're due (or `force`). Returns when the rules last changed.
    func updateBlockingRules(force: Bool) async throws -> Date?

    /// Forgets cookies and site storage for a profile.
    func clearWebsiteData(for profile: BrowsingProfile) async

    /// Throws away everything the ephemeral (private) profile stored. Its pages must be closed first.
    func resetEphemeralProfile()

    /// Where downloads are saved.
    var downloadsDirectory: URL { get set }

    /// Developer tools on every page (with `.developerTools`): Inspect Element in the context menu.
    var developerToolsEnabled: Bool { get set }
}

public struct EngineInfo: Sendable, Equatable {
    /// Stable identifier, e.g. "webkit". Saved with session state so a page is only ever
    /// restored by the engine that made it.
    public let id: String
    /// Shown in Settings, e.g. "WebKit".
    public let name: String
    public let version: String
    public let capabilities: EngineCapabilities

    public init(id: String, name: String, version: String, capabilities: EngineCapabilities) {
        self.id = id
        self.name = name
        self.version = version
        self.capabilities = capabilities
    }
}

/// What an engine supports. Features the app offers are gated on these, never on the engine's id.
public struct EngineCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Declarative ad/tracker blocking (WebKit content rule lists, Chromium's declarativeNetRequest).
    public static let contentBlocking = Self(rawValue: 1 << 0)
    /// Scripts injected into pages in an isolated world (cookie banners, Reader).
    public static let isolatedScripts = Self(rawValue: 1 << 1)
    /// Back/forward list and scroll positions can be saved and restored.
    public static let sessionRestore = Self(rawValue: 1 << 2)
    public static let pageZoom = Self(rawValue: 1 << 3)
    public static let findInPage = Self(rawValue: 1 << 4)
    /// The page can be inspected with developer tools.
    public static let developerTools = Self(rawValue: 1 << 5)
    /// Passkeys and security keys (WebAuthn). WebKit needs Apple's browser entitlement for this.
    public static let passkeys = Self(rawValue: 1 << 6)
    /// Chrome Web Store extensions. No engine offers this yet; a Chromium engine could.
    public static let chromeExtensions = Self(rawValue: 1 << 7)
    /// Safari Web Extensions.
    public static let webExtensions = Self(rawValue: 1 << 8)
}

/// Which cookie jar and storage a page uses.
public enum BrowsingProfile: Hashable, Sendable {
    /// Saved between launches.
    case standard
    /// In memory, shared by every private page, gone once they all close.
    case ephemeral
}

public struct PageOptions: Sendable {
    public var profile: BrowsingProfile
    public var url: URL?
    /// What `EnginePage.sessionState()` returned for this tab earlier.
    public var sessionState: Data?
    /// Off for pages the app renders itself, like Reader, so nothing on them can run.
    public var allowsJavaScript: Bool

    public init(profile: BrowsingProfile = .standard, url: URL? = nil, sessionState: Data? = nil,
                allowsJavaScript: Bool = true) {
        self.profile = profile
        self.url = url
        self.sessionState = sessionState
        self.allowsJavaScript = allowsJavaScript
    }
}

/// Blocking settings, in engine-neutral terms. Rule groups are named by the app ("ads", "privacy"…);
/// each engine maps them to its own rule format.
public struct BlockingConfiguration: Sendable, Equatable {
    public var isEnabled: Bool
    public var ruleGroups: Set<String>
    /// Hosts where nothing is blocked.
    public var allowlist: Set<String>
    public var declineCookieBanners: Bool
    /// Tell sites not to sell or share data (Global Privacy Control, `navigator.globalPrivacyControl`).
    public var globalPrivacyControl: Bool

    public init(isEnabled: Bool, ruleGroups: Set<String>, allowlist: Set<String>, declineCookieBanners: Bool,
                globalPrivacyControl: Bool = false) {
        self.isEnabled = isEnabled
        self.ruleGroups = ruleGroups
        self.allowlist = allowlist
        self.declineCookieBanners = declineCookieBanners
        self.globalPrivacyControl = globalPrivacyControl
    }
}

// MARK: - Page

/// One web page: what a tab shows. Made by `BrowserEngine.makePage`.
@MainActor
public protocol EnginePage: AnyObject {
    var id: UUID { get }
    /// Live state for the UI to observe.
    var state: PageState { get }
    /// The view to put on screen. A page has one view; moving it between windows is fine.
    var view: PlatformView { get }
    var delegate: (any EnginePageDelegate)? { get set }

    func load(_ url: URL)
    /// Shows HTML the app made (Reader). Relative links resolve against `baseURL`.
    func loadHTML(_ html: String, baseURL: URL?)
    func reload()
    /// Reloads without the cache, and asks the navigation policy again.
    func reloadFromOrigin()
    func stopLoading()
    func goBack()
    func goForward()

    /// Page zoom, 1 = 100%.
    var zoom: Double { get set }
    /// Nil uses the engine's own user agent.
    var customUserAgent: String? { get set }

    /// Highlights the next match. Returns false when there isn't one.
    func find(_ text: String, backwards: Bool) async -> Bool
    func clearFind()

    /// Back/forward list and scroll position, for `PageOptions.sessionState`.
    func sessionState() -> Data?

    /// Runs a script body (it may `return` and `await`) in an isolated world, out of the page's reach.
    func evaluate(_ body: String, inWorld world: String) async throws -> Any?

    /// A picture of the visible page.
    func snapshot() async -> CGImage?

    /// Stops everything and lets go of the engine's resources.
    func close()
}

/// What the browser chrome shows about a page. Engines update it on the main actor.
@MainActor @Observable
public final class PageState {
    public var url: URL?
    public var title = ""
    public var progress: Double = 0
    public var isLoading = false
    public var canGoBack = false
    public var canGoForward = false
    /// Every resource arrived over an encrypted connection.
    public var isSecure = false
    /// The colour the page wants around it (`<meta name="theme-color">`), if any.
    public var themeColor: CGColor?

    public init() {}
}

// MARK: - Delegate

/// The app's side of a page: decisions, dialogs and events. Every method has a sensible default,
/// so a minimal host only implements what it needs.
@MainActor
public protocol EnginePageDelegate: AnyObject {
    /// Every navigation asks first. Main-frame and sub-frame alike.
    func page(_ page: any EnginePage, decide request: NavigationRequest) async -> NavigationDecision
    func page(_ page: any EnginePage, didCommit url: URL?)
    func page(_ page: any EnginePage, didFinish url: URL, title: String)
    /// The page never arrived. Cancellations are filtered out already.
    func page(_ page: any EnginePage, didFailWith error: NSError)
    /// The page's process crashed or was killed.
    func pageContentProcessDidTerminate(_ page: any EnginePage)

    /// The page opened a window (target=_blank, window.open). Return a delegate to keep the new
    /// page, which keeps `window.opener` working, or nil to block it. The host must hold on to `popup`.
    func page(_ page: any EnginePage, openedPopup popup: any EnginePage, url: URL?) -> (any EnginePageDelegate)?
    /// The page called window.close().
    func pageDidRequestClose(_ page: any EnginePage)

    func page(_ page: any EnginePage, show dialog: EngineDialog) async -> EngineDialogResponse
    func page(_ page: any EnginePage, requestPermission permission: EnginePermission, host: String) async -> Bool
    /// `<input type=file>`. Nil cancels.
    func page(_ page: any EnginePage, chooseFiles request: FileChooserRequest) async -> [URL]?
    func page(_ page: any EnginePage, didStartDownload download: EngineDownload)
    /// The cookie-banner script declined a banner on this page.
    func pageDidDeclineCookieBanner(_ page: any EnginePage)
}

public extension EnginePageDelegate {
    func page(_ page: any EnginePage, decide request: NavigationRequest) async -> NavigationDecision { .allow }
    func page(_ page: any EnginePage, didCommit url: URL?) {}
    func page(_ page: any EnginePage, didFinish url: URL, title: String) {}
    func page(_ page: any EnginePage, didFailWith error: NSError) {}
    func pageContentProcessDidTerminate(_ page: any EnginePage) { page.reload() }
    func page(_ page: any EnginePage, openedPopup popup: any EnginePage, url: URL?) -> (any EnginePageDelegate)? { nil }
    func pageDidRequestClose(_ page: any EnginePage) {}
    func page(_ page: any EnginePage, show dialog: EngineDialog) async -> EngineDialogResponse { .cancel }
    func page(_ page: any EnginePage, requestPermission permission: EnginePermission, host: String) async -> Bool { false }
    func page(_ page: any EnginePage, chooseFiles request: FileChooserRequest) async -> [URL]? { nil }
    func page(_ page: any EnginePage, didStartDownload download: EngineDownload) {}
    func pageDidDeclineCookieBanner(_ page: any EnginePage) {}
}

public struct NavigationRequest: Sendable {
    public enum Kind: Sendable { case link, formSubmit, backForward, reload, other }

    public let url: URL
    public let kind: Kind
    public let isMainFrame: Bool
    /// "GET", "POST"…
    public let method: String
    /// Cmd-click or a middle click on a link: the user wants it in a new tab.
    public let wantsNewTab: Bool
    /// Shift was held too, so the new tab should come to the front.
    public let wantsForeground: Bool

    public init(url: URL, kind: Kind, isMainFrame: Bool, method: String, wantsNewTab: Bool = false, wantsForeground: Bool = false) {
        self.url = url
        self.kind = kind
        self.isMainFrame = isMainFrame
        self.method = method
        self.wantsNewTab = wantsNewTab
        self.wantsForeground = wantsForeground
    }
}

public enum NavigationDecision: Sendable, Equatable {
    case allow
    case cancel
    /// Load this URL instead (e.g. with tracking parameters removed).
    case redirect(URL)
    /// Save the response as a file.
    case download
    /// Allow, asking for the site's desktop or mobile layout and this user agent (nil = default).
    case allowWith(desktopMode: Bool, userAgent: String?)
}

public enum EngineDialog: Sendable, Equatable {
    case alert(host: String, message: String)
    case confirm(host: String, message: String)
    case prompt(host: String, message: String, defaultText: String)
    /// HTTP Basic/Digest sign-in.
    case credentials(host: String, realm: String?)
}

public enum EngineDialogResponse: Sendable, Equatable {
    case ok
    case cancel
    case text(String)
    case credentials(user: String, password: String)
}

public enum EnginePermission: String, Sendable, Codable, CaseIterable {
    case camera, microphone, cameraAndMicrophone, location, notifications

    public var phrase: String {
        switch self {
        case .camera: "use your camera"
        case .microphone: "use your microphone"
        case .cameraAndMicrophone: "use your camera and microphone"
        case .location: "know your location"
        case .notifications: "send notifications"
        }
    }
}

public struct FileChooserRequest: Sendable {
    public let allowsMultiple: Bool
    public let allowsDirectories: Bool
    public init(allowsMultiple: Bool, allowsDirectories: Bool) {
        self.allowsMultiple = allowsMultiple
        self.allowsDirectories = allowsDirectories
    }
}

// MARK: - Downloads

/// A file being saved. Engines create and update it; the app lists it.
@MainActor @Observable
public final class EngineDownload: Identifiable {
    public enum Status: Equatable, Sendable { case running, finished, failed(String), cancelled }

    public let id = UUID()
    public var filename: String
    public var sourceURL: URL?
    public var fileURL: URL?
    public var progress: Double = 0
    public var status: Status = .running
    public let startedAt = Date()
    @ObservationIgnored public var cancelHandler: (() -> Void)?

    public init(filename: String, sourceURL: URL?) {
        self.filename = filename
        self.sourceURL = sourceURL
    }

    public func cancel() {
        cancelHandler?()
        if status == .running { status = .cancelled }
    }
}
