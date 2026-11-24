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

    /// The profile's cookies a request to `url` would carry, so the app can fetch as the signed-in
    /// person (Live Folders read github.com this way, as Arc did).
    func cookies(for profile: BrowsingProfile, url: URL) async -> [HTTPCookie]

    /// Throws away everything the ephemeral (private) profile stored. Its pages must be closed first.
    func resetEphemeralProfile()

    /// Deletes a `.persistent` profile's store for good. Its pages must be closed first.
    func deleteProfile(_ id: UUID) async

    /// Where downloads are saved.
    var downloadsDirectory: URL { get set }

    /// Developer tools on every page (with `.developerTools`): Inspect Element in the context menu.
    var developerToolsEnabled: Bool { get set }

    // Extensions (with `.webExtensions`). Engines without them keep the defaults below.

    /// The extensions running now, in toolbar order.
    var extensions: [EngineExtension] { get }
    /// The app's windows and tabs, as extensions see them. Set before loading extensions.
    var extensionHost: (any EngineExtensionHost)? { get set }
    /// Finds and starts the extensions installed on this machine. Returns what couldn't load, for logs.
    func loadInstalledExtensions() async -> [String]
    /// Unpacked extensions in `folders` (Browsa's store installs, folders the user picked), and with
    /// `includeApps` the Safari extensions inside installed apps.
    func loadInstalledExtensions(folders: [ExtensionFolder], includeApps: Bool) async -> [String]
    /// Stops every extension.
    func unloadExtensions()
    /// The extension's toolbar button was clicked. Its popup, if it has one, appears at `anchor`.
    func performAction(extensionID: String, for page: (any EnginePage)?, anchor: PlatformView?)
    /// An extension's toolbar action as it stands for `page`: its label, badge and icon there.
    func extensionActionState(extensionID: String, for page: (any EnginePage)?) -> EngineActionState?
    /// A tab came to the front of its window, or its window came to the front.
    func pageDidBecomeActive(_ page: any EnginePage)
}

public extension BrowserEngine {
    func deleteProfile(_ id: UUID) async {}
    func cookies(for profile: BrowsingProfile, url: URL) async -> [HTTPCookie] { [] }
    var extensions: [EngineExtension] { [] }
    var extensionHost: (any EngineExtensionHost)? { get { nil } set {} }
    func loadInstalledExtensions() async -> [String] { [] }
    func loadInstalledExtensions(folders: [ExtensionFolder], includeApps: Bool) async -> [String] {
        guard includeApps else { return [] }
        return await loadInstalledExtensions()
    }
    func unloadExtensions() {}
    func performAction(extensionID: String, for page: (any EnginePage)?, anchor: PlatformView?) {}
    func extensionActionState(extensionID: String, for page: (any EnginePage)?) -> EngineActionState? { nil }
    func pageDidBecomeActive(_ page: any EnginePage) {}
}

// MARK: - Extensions

/// A browser extension, for the toolbar and Settings.
public struct EngineExtension: Identifiable {
    /// Stable across launches, e.g. the extension's bundle identifier.
    public let id: String
    public let name: String
    public let version: String
    public let icon: CGImage?
    /// It has a toolbar button (a browser action).
    public let hasAction: Bool
    /// A page for Browsa's right panel (Chrome's side panel, Firefox's sidebar), if it has one.
    public let panelURL: URL?
    /// Its settings page (`options_ui` or `options_page`), if it has one.
    public let optionsURL: URL?

    public init(id: String, name: String, version: String, icon: CGImage?, hasAction: Bool, panelURL: URL? = nil,
                optionsURL: URL? = nil) {
        self.optionsURL = optionsURL
        self.id = id
        self.name = name
        self.version = version
        self.icon = icon
        self.hasAction = hasAction
        self.panelURL = panelURL
    }
}

/// An unpacked extension for the engine to load: a folder with a manifest.json.
public struct ExtensionFolder: Sendable, Hashable {
    /// Stable id, e.g. "chrome:<extension id>". The engine uses it as the extension's unique identifier.
    public let id: String
    public let url: URL

    public init(id: String, url: URL) {
        self.id = id
        self.url = url
    }
}

/// One window as extensions see it: its tabs' pages in order and the one in front.
public struct EngineWindowInfo {
    public let id: UUID
    public let pages: [any EnginePage]
    public let activePage: (any EnginePage)?
    public let isFocused: Bool
    public let isPrivate: Bool
    /// In screen coordinates.
    public let frame: CGRect

    public init(id: UUID, pages: [any EnginePage], activePage: (any EnginePage)?, isFocused: Bool, isPrivate: Bool, frame: CGRect) {
        self.id = id
        self.pages = pages
        self.activePage = activePage
        self.isFocused = isFocused
        self.isPrivate = isPrivate
        self.frame = frame
    }
}

/// The app's side of extensions: its windows and tabs, and what extensions may do with them.
@MainActor
public protocol EngineExtensionHost: AnyObject {
    /// Open windows, the focused one first.
    var extensionWindows: [EngineWindowInfo] { get }
    func focusExtensionWindow(_ id: UUID)
    /// A new tab, in `windowID` or the focused window. Returns its page.
    func openExtensionTab(url: URL?, windowID: UUID?, active: Bool) -> (any EnginePage)?
    func activateExtensionTab(_ page: any EnginePage)
    func closeExtensionTab(_ page: any EnginePage)
    /// An extension changed its toolbar action (badge, icon, label) for some page.
    func extensionActionsDidChange()
    /// `chrome.sidePanel.open`, or a toolbar click with `openPanelOnActionClick`: show the extension's
    /// side panel page. False if it has none.
    func showExtensionPanel(extensionID: String) -> Bool
}

public extension EngineExtensionHost {
    func extensionActionsDidChange() {}
    func showExtensionPanel(extensionID: String) -> Bool { false }
}

/// An extension's toolbar action for one page.
public struct EngineActionState: Equatable {
    public var label: String
    /// Chrome's badge, e.g. a blocked count.
    public var badgeText: String
    /// The badge changed and the user hasn't opened the popup since.
    public var hasUnreadBadge: Bool
    public var isEnabled: Bool
    public var icon: CGImage?

    public init(label: String, badgeText: String, hasUnreadBadge: Bool, isEnabled: Bool, icon: CGImage?) {
        self.label = label
        self.badgeText = badgeText
        self.hasUnreadBadge = hasUnreadBadge
        self.isEnabled = isEnabled
        self.icon = icon
    }

    /// The extension has something for this page: a badge, or one the user hasn't seen.
    public var hasSomethingForPage: Bool { hasUnreadBadge || !badgeText.isEmpty }
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
    /// Saved between launches, in a store of its own: a profile a space uses, so its logins stay
    /// apart from every other profile's.
    case persistent(UUID)
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
    /// Which match the last `find` landed on, out of how many. Nil when the engine can't tell.
    func findMatches(_ text: String) async -> FindMatches?
    func clearFind()

    /// Back/forward list and scroll position, for `PageOptions.sessionState`.
    func sessionState() -> Data?

    /// Runs a script body (it may `return` and `await`) in an isolated world, out of the page's reach.
    /// The world named "page" is the page's own, for developer tools on your own sites.
    func evaluate(_ body: String, inWorld world: String) async throws -> Any?

    /// A picture of the visible page.
    func snapshot() async -> CGImage?

    /// Plays, pauses or pops out the page's main video or audio. `state.media` says what there is.
    func media(_ action: MediaAction)

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
    /// The page has the camera or microphone on right now (a call): closing it, or quitting, ends that.
    public var isCapturingMedia = false
    /// The camera or microphone is on (muted counts: the call is still going).
    public var isCapturing = false
    /// The camera alone, and the microphone alone, for the call badge.
    public var camera: CaptureState = .off
    public var microphone: CaptureState = .off
    /// Audio or video is playing with sound.
    public var isPlayingAudio = false
    /// Someone typed into a field on the page and it still holds text.
    public var hasUnsavedInput = false
    /// The page's video and audio, for picture in picture and the sidebar's play button.
    public var media = PageMedia()

    /// Unloading the page now would cut off a call, the music or a draft.
    public var isBusy: Bool { isCapturing || isPlayingAudio || hasUnsavedInput }

    public init() {}
}

/// What a page's video and audio are doing.
public struct PageMedia: Equatable, Sendable {
    /// A video big enough to pop out (not an icon-sized loop).
    public var hasVideo = false
    /// Something is playing, with sound or without.
    public var isPlaying = false
    /// Something played with sound since the page loaded, so a paused video still gets a play button.
    public var hasPlayed = false
    /// Something is playing with sound.
    public var isAudible = false
    /// A video with sound is playing: the one to pop out when you leave the tab.
    public var isWatching = false
    /// A video is in picture in picture.
    public var isPictureInPicture = false

    public init(hasVideo: Bool = false, isPlaying: Bool = false, hasPlayed: Bool = false, isAudible: Bool = false,
                isWatching: Bool = false, isPictureInPicture: Bool = false) {
        self.hasVideo = hasVideo
        self.isPlaying = isPlaying
        self.hasPlayed = hasPlayed
        self.isAudible = isAudible
        self.isWatching = isWatching
        self.isPictureInPicture = isPictureInPicture
    }
}

/// Something to do to a page's main video or audio.
public enum MediaAction: Sendable {
    case playPause
    case togglePictureInPicture, enterPictureInPicture, exitPictureInPicture
}

/// A camera or microphone, as the page has it.
public enum CaptureState: Sendable {
    case off, on, muted
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
    /// The same, with what the page asked for in `window.open`'s features (a size, usually for a sign-in).
    /// Hosts that don't care can leave this alone: it calls the version without features.
    func page(_ page: any EnginePage, openedPopup popup: any EnginePage, url: URL?,
              features: PopupFeatures) -> (any EnginePageDelegate)?
    /// The page called window.close().
    func pageDidRequestClose(_ page: any EnginePage)

    func page(_ page: any EnginePage, show dialog: EngineDialog) async -> EngineDialogResponse
    func page(_ page: any EnginePage, requestPermission permission: EnginePermission, host: String) async -> Bool
    /// A site's certificate failed the system's checks. True loads the site anyway (the user
    /// trusted this certificate before, or allows local network sites); false shows the error.
    func page(_ page: any EnginePage, trusts certificate: ServerCertificate) -> Bool
    /// `<input type=file>`. Nil cancels.
    func page(_ page: any EnginePage, chooseFiles request: FileChooserRequest) async -> [URL]?
    func page(_ page: any EnginePage, didStartDownload download: EngineDownload)
    /// The cookie-banner script declined a banner on this page.
    func pageDidDeclineCookieBanner(_ page: any EnginePage)
    /// The video window's "back to tab" button was pressed for this page's video. The video only goes back
    /// once the page is on screen, so show its tab.
    func pageWantsVideoBack(_ page: any EnginePage)
    /// The page showed a web notification. The site already has permission. False if it couldn't be shown
    /// (notifications are off for the app in the system, say), which the page hears as an error.
    func page(_ page: any EnginePage, showNotification notification: WebNotification) async -> Bool
    /// The page closed one of its notifications.
    func page(_ page: any EnginePage, closeNotification id: String, tag: String?)
}

/// What a page asked for when it opened a window. A plain `target=_blank` or `window.open(url)` asks
/// for nothing; sign-in flows (Google, Apple, Microsoft, Okta) ask for a size.
public struct PopupFeatures: Sendable, Equatable {
    public var width: Double?
    public var height: Double?
    /// The page asked for a window without toolbars (`popup` in the features string, or toolbar=no).
    public var hidesToolbars: Bool

    public init(width: Double? = nil, height: Double? = nil, hidesToolbars: Bool = false) {
        self.width = width
        self.height = height
        self.hidesToolbars = hidesToolbars
    }

    /// The page wants a small window of its own rather than a tab, as Safari and Chrome give it.
    public var wantsWindow: Bool { width != nil || height != nil || hidesToolbars }
}

/// Find on page progress: the current match (1-based, 0 if unknown) and how many there are.
public struct FindMatches: Sendable, Equatable {
    public var current: Int
    public var total: Int
    /// Counting stopped at `total`; there may be more.
    public var capped: Bool

    public init(current: Int, total: Int, capped: Bool) {
        self.current = current
        self.total = total
        self.capped = capped
    }
}

public extension EnginePage {
    func findMatches(_ text: String) async -> FindMatches? { nil }
    func media(_ action: MediaAction) {}
}

/// A site's notification (`new Notification(…)` or a service worker's `showNotification`).
public struct WebNotification: Sendable, Equatable {
    /// The page's own id for it, to send the click back with.
    public var id: String
    public var title: String
    public var body: String
    /// The site that sent it.
    public var host: String
    /// A newer notification with the same tag replaces the older one.
    public var tag: String?
    public var icon: URL?
    public var silent: Bool

    public init(id: String, title: String, body: String, host: String, tag: String?, icon: URL?, silent: Bool) {
        self.id = id
        self.title = title
        self.body = body
        self.host = host
        self.tag = tag
        self.icon = icon
        self.silent = silent
    }
}

/// Engines that show sites' notifications.
@MainActor
public protocol WebNotificationsConfigurable: AnyObject {
    /// Each site's saved answer (host: allowed), so pages know it before they ask.
    var notificationPermissions: [String: Bool] { get set }
    /// A notification from `page` was clicked: fire its `click` event.
    func notificationClicked(_ id: String, on page: any EnginePage)
}

public extension EnginePageDelegate {
    func page(_ page: any EnginePage, decide request: NavigationRequest) async -> NavigationDecision { .allow }
    func page(_ page: any EnginePage, didCommit url: URL?) {}
    func page(_ page: any EnginePage, didFinish url: URL, title: String) {}
    func page(_ page: any EnginePage, didFailWith error: NSError) {}
    func pageContentProcessDidTerminate(_ page: any EnginePage) { page.reload() }
    func page(_ page: any EnginePage, openedPopup popup: any EnginePage, url: URL?) -> (any EnginePageDelegate)? { nil }
    func page(_ page: any EnginePage, openedPopup popup: any EnginePage, url: URL?,
              features: PopupFeatures) -> (any EnginePageDelegate)? {
        self.page(page, openedPopup: popup, url: url)
    }
    func pageDidRequestClose(_ page: any EnginePage) {}
    func page(_ page: any EnginePage, show dialog: EngineDialog) async -> EngineDialogResponse { .cancel }
    func page(_ page: any EnginePage, requestPermission permission: EnginePermission, host: String) async -> Bool { false }
    func page(_ page: any EnginePage, trusts certificate: ServerCertificate) -> Bool { false }
    func page(_ page: any EnginePage, chooseFiles request: FileChooserRequest) async -> [URL]? { nil }
    func page(_ page: any EnginePage, didStartDownload download: EngineDownload) {}
    func pageDidDeclineCookieBanner(_ page: any EnginePage) {}
    func pageWantsVideoBack(_ page: any EnginePage) {}
    func page(_ page: any EnginePage, showNotification notification: WebNotification) async -> Bool { false }
    func page(_ page: any EnginePage, closeNotification id: String, tag: String?) {}
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
    /// Option-click on a link: the user wants a quick look (Glance) without leaving the page.
    public let wantsGlance: Bool

    public init(url: URL, kind: Kind, isMainFrame: Bool, method: String, wantsNewTab: Bool = false, wantsForeground: Bool = false,
                wantsGlance: Bool = false) {
        self.url = url
        self.kind = kind
        self.isMainFrame = isMainFrame
        self.method = method
        self.wantsNewTab = wantsNewTab
        self.wantsForeground = wantsForeground
        self.wantsGlance = wantsGlance
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
    /// Sharing the screen (getDisplayMedia). Asked every time, never remembered.
    case screen

    public var phrase: String {
        switch self {
        case .screen: "share your entire screen"
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

// MARK: - Call audio

/// How Browsa processes the microphone on calls (Meet, Zoom, Teams and the like). Settings › Audio.
public struct CallAudioTuning: Codable, Equatable, Sendable {
    public enum Processing: String, Codable, Sendable { case browsa, system }
    /// Which inputs of an audio interface make up the mic. Some interfaces put a mic on input 2 only.
    public enum Inputs: String, Codable, Sendable { case mix, first, second }

    /// Browsa's own processing (WebRTC's, as in Chrome), or the system's voice processing.
    // Apple's processing unless chosen: calls get Browsa's processing from Browsa's own WebKit where it runs; the
    // in-page script is the opt-in for Apple's WebKit (older macOS, Intel).
    public var processing: Processing = .system
    public var inputs: Inputs = .mix
    /// -1 off, 0 low, 1 moderate, 2 high, 3 very high.
    public var noiseSuppression: Int = 2
    /// Speaker-to-mic delay hint for the echo canceller, in ms. 0 lets it find the delay itself.
    public var echoDelayMs: Int = 0
    /// Mic level before any processing, in dB.
    public var micLevelDb: Double = 0
    /// Auto gain: how fast it may turn the mic up or down, in dB per second.
    public var gainSpeed: Double = 3
    /// Auto gain: it never lifts background noise above this, in dBFS.
    public var noiseCeilingDb: Double = -50
    public var rumbleFilter = true
    public var typingRemover = false
    /// Automatic mic volume, for sites that ask for it (Meet, Zoom and Teams do).
    public var autoGain = true

    public init() {}

    // Settings saved by older versions lack newer keys: those take their defaults instead of the whole
    // setting being thrown away.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CallAudioTuning()
        processing = try c.decodeIfPresent(Processing.self, forKey: .processing) ?? d.processing
        inputs = try c.decodeIfPresent(Inputs.self, forKey: .inputs) ?? d.inputs
        noiseSuppression = try c.decodeIfPresent(Int.self, forKey: .noiseSuppression) ?? d.noiseSuppression
        echoDelayMs = try c.decodeIfPresent(Int.self, forKey: .echoDelayMs) ?? d.echoDelayMs
        micLevelDb = try c.decodeIfPresent(Double.self, forKey: .micLevelDb) ?? d.micLevelDb
        gainSpeed = try c.decodeIfPresent(Double.self, forKey: .gainSpeed) ?? d.gainSpeed
        noiseCeilingDb = try c.decodeIfPresent(Double.self, forKey: .noiseCeilingDb) ?? d.noiseCeilingDb
        rumbleFilter = try c.decodeIfPresent(Bool.self, forKey: .rumbleFilter) ?? d.rumbleFilter
        typingRemover = try c.decodeIfPresent(Bool.self, forKey: .typingRemover) ?? d.typingRemover
        autoGain = try c.decodeIfPresent(Bool.self, forKey: .autoGain) ?? d.autoGain
    }

    /// What the call audio script reads. Settings › Audio offers the processing, the input, the noise level
    /// (low to high) and auto gain; the rest are fixed at their defaults, whatever an older version saved.
    public var scriptValue: [String: Any] {
        let d = CallAudioTuning()
        return ["inputs": inputs.rawValue, "noise": max(0, min(noiseSuppression, 2)), "autoGain": autoGain,
                "delayMs": d.echoDelayMs, "micLevelDb": d.micLevelDb, "gainSpeed": d.gainSpeed,
                "noiseCeilingDb": d.noiseCeilingDb, "rumble": d.rumbleFilter, "typing": d.typingRemover]
    }
}

/// The latest numbers from a page using call audio, about once a second.
public struct CallAudioStats: Sendable, Equatable {
    public var micDb: Double
    public var gainDb: Double?
    /// How much echo the echo canceller removes, in dB.
    public var echoRemovedDb: Double?
    /// The speaker-to-mic delay the echo canceller measured, in ms.
    public var delayMs: Double?
    /// 0...1: how likely it is that echo still gets through.
    public var echoLeakLikelihood: Double?
    public var engine: String
    public var hasReference: Bool
    public var at: Date

    public init(micDb: Double, gainDb: Double?, echoRemovedDb: Double?, delayMs: Double?, echoLeakLikelihood: Double?,
                engine: String, hasReference: Bool, at: Date = Date()) {
        self.micDb = micDb; self.gainDb = gainDb; self.echoRemovedDb = echoRemovedDb; self.delayMs = delayMs
        self.echoLeakLikelihood = echoLeakLikelihood; self.engine = engine; self.hasReference = hasReference; self.at = at
    }
}

/// Engines that can run Boosts (`Boost`).
@MainActor
public protocol BoostsConfigurable: AnyObject {
    /// The ids of the styles turned on. Changes apply to open pages straight away, without a reload.
    var enabledBoosts: Set<String> { get set }
    /// Boosts people made themselves, one per site, that are on. Pages loaded from now on get them; a page
    /// open now gets a changed style straight away (`PageBoost.previewSource`), its script on the next load.
    var userBoosts: [PageBoost] { get set }
}

/// A Boost someone made for one site: their own CSS and script. The script runs in its own world
/// (`world`), so it sees the page's DOM but never the page's JavaScript.
public struct PageBoost: Sendable, Equatable {
    /// "example.com" also covers its subdomains.
    public var host: String
    public var css: String
    public var script: String

    public init(host: String, css: String, script: String) {
        self.host = host
        self.css = css
        self.script = script
    }

    /// The world Boost styles and scripts run in.
    public static let world = "browsa.boost"

    /// Defines `__browsaBoostCSS(css)` in the Boost world: replaces the Boost's style sheet. A constructed
    /// sheet isn't inline style, so sites' Content Security Policies don't block it; a <style> element is
    /// the fallback.
    public static let applyCSSFunction = """
    globalThis.__browsaBoostCSS = globalThis.__browsaBoostCSS || ((css) => {
      try {
        let sheet = globalThis.__browsaBoostSheet;
        if (!sheet) {
          sheet = new CSSStyleSheet();
          globalThis.__browsaBoostSheet = sheet;
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        }
        sheet.replaceSync(css);
      } catch (e) {
        const put = () => {
          let s = document.getElementById('__browsa_boost');
          if (!s) { s = document.createElement('style'); s.id = '__browsa_boost'; (document.head || document.documentElement).appendChild(s); }
          s.textContent = css;
        };
        if (document.documentElement) put(); else document.addEventListener('DOMContentLoaded', put, { once: true });
      }
    });
    """

    /// Shows `css` on a page that's open now, replacing what its Boost showed before. Run in `world`.
    public static func previewSource(css: String) -> String {
        applyCSSFunction + "\n__browsaBoostCSS(\(jsString(css))); return true;"
    }

    /// A Swift string as a JavaScript string literal.
    public static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    public func matches(_ host: String) -> Bool { host == self.host || host.hasSuffix("." + self.host) }
}

/// Engines that can run Browsa's call audio.
@MainActor
public protocol CallAudioConfigurable: AnyObject {
    var callAudio: CallAudioTuning { get set }
    var onCallAudioStats: ((CallAudioStats) -> Void)? { get set }
}
