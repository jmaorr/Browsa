import AppKit
import Observation
import BrowserCore
import BrowserEngine
import Suggest

/// Ties one tab to its live page: mirrors the page's state onto the tab, and answers the page's
/// questions for the browser.
@MainActor
final class TabController: EnginePageDelegate {
    let tab: BrowserTab
    /// The engine the page runs on (`EngineInfo.id`): WebKit, or Chromium for a call tab.
    let engineID: String
    private(set) var page: (any EnginePage)!
    private weak var library: Library?
    /// The window showing this tab, if any.
    private var window: Browser? { library?.window(showing: tab) }
    /// How the next finished load should count in history.
    private var pendingSource: Frecency.VisitSource?
    /// The page's process died while it was out of sight. Reload when it's shown again.
    private var needsRecovery = false
    private var lastTermination: Date?

    init(tab: BrowserTab, library: Library, engineID: String? = nil, makePage: (TabController) -> any EnginePage) {
        self.tab = tab
        self.engineID = engineID ?? library.engine.info.id
        self.library = library
        page = makePage(self)
        page.delegate = self
        if let host = tab.url?.host() { setZoom(Preferences.zoom(for: host)) }
        mirror()
    }

    /// Copies the page's live state onto the tab whenever it changes.
    private func mirror() {
        guard let page else { return }
        withObservationTracking {
            let s = page.state
            _ = (s.url, s.title, s.progress, s.isLoading, s.canGoBack, s.canGoForward, s.isSecure, s.camera, s.microphone, s.media)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.mirror()
            }
        }
        sync()
    }

    private func sync() {
        guard let s = page?.state else { return }
        if let url = s.url, tab.url != url { tab.url = url }
        if !s.title.isEmpty, tab.title != s.title { tab.title = s.title }
        // Only real changes, so views watching the tab don't redraw for nothing.
        if tab.estimatedProgress != s.progress { tab.estimatedProgress = s.progress }
        if tab.isLoading != s.isLoading { tab.isLoading = s.isLoading }
        if tab.canGoBack != s.canGoBack { tab.canGoBack = s.canGoBack }
        if tab.canGoForward != s.canGoForward { tab.canGoForward = s.canGoForward }
        let call = s.camera == .off && s.microphone == .off ? nil : TabCall(camera: s.camera == .on, microphone: s.microphone == .on)
        if tab.call != call { tab.call = call }
        let m = s.media
        let media = TabMedia(hasVideo: m.hasVideo, isPlaying: m.isPlaying, hasPlayed: m.hasPlayed,
                             isAudible: m.isAudible, isWatching: m.isWatching, isPictureInPicture: m.isPictureInPicture)
        if tab.media != media {
            let wasOut = tab.media.isPictureInPicture
            tab.media = media
            if wasOut, !media.isPictureInPicture { library?.videoPiP.didLeavePictureInPicture(tab) }
        }
    }

    func load(_ url: URL, source: Frecency.VisitSource) {
        if let library, library.needsEngineSwap(self, to: url) {
            library.swapEngine(of: tab, to: url, source: source)
            return
        }
        pendingSource = source
        tab.loadError = nil
        page.load(url)
    }

    func freeze() {
        if let state = page?.sessionState() { tab.interactionState = state }
    }

    func recoverIfNeeded() {
        guard needsRecovery else { return }
        needsRecovery = false
        page.reload()
    }

    // MARK: Zoom

    /// Zooms the page and keeps the tab's copy in step, so the address bar's badge updates straight away.
    private func setZoom(_ z: Double) {
        page.zoom = z
        if tab.pageZoom != z { tab.pageZoom = z }
    }

    private static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.85, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    func zoom(by direction: Int) {
        let current = page.zoom
        let next: Double
        if direction == 0 {
            next = 1
        } else if direction > 0 {
            next = Self.zoomSteps.first { $0 > current + 0.001 } ?? Self.zoomSteps.last!
        } else {
            next = Self.zoomSteps.last { $0 < current - 0.001 } ?? Self.zoomSteps.first!
        }
        setZoom(next)
        // Private tabs zoom for now only: the saved per-site zoom would record the host.
        if !tab.isPrivate, let host = tab.url?.host() { Preferences.setZoom(next, for: host) }
        window?.showToast(direction == 0 ? "Actual Size" : "Zoom \(Int((next * 100).rounded()))%")
    }

    // MARK: EnginePageDelegate

    func page(_ page: any EnginePage, decide request: NavigationRequest) async -> NavigationDecision {
        guard let library else { return .allow }
        if request.wantsGlance {
            guard let window = library.window(showing: tab) ?? library.activeWindow else { return .allow }
            window.openGlance(request.url, isPrivate: tab.isPrivate)
            return .cancel
        }
        if request.wantsNewTab {
            library.openInNewTab(request.url, from: tab, foreground: request.wantsForeground)
            return .cancel
        }
        let scheme = request.url.scheme?.lowercased() ?? ""
        guard ["http", "https", "about", "blob", "data", "file", "javascript", "webkit-extension"].contains(scheme) else {
            // mailto:, zoommtg:, App Store links and the like belong to other apps. Browsa asks first (as
            // Chrome does), so a page can't throw you into an app: Zoom's join page fires zoommtg: on its
            // own, and saying no keeps its "join from your browser" option. Email links just open.
            Task { await openInApp(request) }
            return .cancel
        }
        // A call site (or leaving one) moves the tab to the engine it runs on.
        if request.isMainFrame, request.method == "GET", library.needsEngineSwap(self, to: request.url) {
            library.swapEngine(of: tab, to: request.url)
            return .cancel
        }
        if request.isMainFrame, library.settings.cleanLinks, request.method == "GET",
           !library.settings.blockingDisabled(for: request.url.host()),
           let clean = LinkCleaner.clean(request.url) {
            return .redirect(clean)
        }
        return .allow
    }

    /// Hands a link to the app that opens it, asking first, as Safari and Chrome do: a page could
    /// otherwise launch Zoom, FaceTime or the App Store by itself. The answer is kept per site and
    /// per kind of link, like camera and microphone. A frame inside the page (an ad, an embed) only
    /// gets to ask when it was a click on a link. Email links open straight away.
    private func openInApp(_ request: NavigationRequest) async {
        let url = request.url
        let scheme = url.scheme?.lowercased() ?? ""
        guard request.isMainFrame || request.kind == .link else { return }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            window?.showToast("No app on this Mac opens \(scheme): links")
            return
        }
        // Typed into the address bar on an empty tab, or an email, phone or message link: no site to ask about.
        guard !["mailto", "tel", "facetime", "sms"].contains(scheme), let host = page.state.url?.host() ?? tab.url?.host(), let library else {
            NSWorkspace.shared.open(url)
            return
        }
        let key = Self.openAppKey(scheme)
        if let saved = library.settings.sitePermissions[host]?[key] {
            if saved { NSWorkspace.shared.open(url) }
            return
        }
        guard let window else { return }
        let app = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
        let answer = await window.ask(.openApp(app: app, host: host), from: tab)
        // Cancelled because the tab went away: don't remember a "no" the user never gave.
        guard answer != .cancel || window.currentTab?.id == tab.id else { return }
        let allowed = answer == .ok
        library.settings.sitePermissions[host, default: [:]][key] = allowed
        if allowed { NSWorkspace.shared.open(url) }
    }

    /// The saved-answer key for opening one kind of link in its app, such as "app:zoommtg".
    static func openAppKey(_ scheme: String) -> String { "app:" + scheme }

    func page(_ page: any EnginePage, didCommit url: URL?) {
        tab.loadError = nil
        library?.windows.forEach { $0.cancelPrompts(for: tab.id) }
        if let host = url?.host() {
            let z = Preferences.zoom(for: host)
            if abs(page.zoom - z) > 0.001 { setZoom(z) }
        }
    }

    func page(_ page: any EnginePage, didFinish url: URL, title: String) {
        library?.scheduleSave()
        guard !tab.isPrivate, let history = library?.history else { pendingSource = nil; return }
        let source = pendingSource ?? .link
        pendingSource = nil
        Task { await history.recordVisit(url: url, title: title, source: source) }
    }

    func page(_ page: any EnginePage, didFailWith error: NSError) {
        let failed = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? page.state.url
        tab.loadError = LoadError(url: failed, error: error)
    }

    func pageContentProcessDidTerminate(_ page: any EnginePage) {
        guard window != nil else { needsRecovery = true; return }
        // Dying again straight after a reload is the page itself; reloading would loop.
        let diedRecently = lastTermination.map { Date().timeIntervalSince($0) < 10 } ?? false
        lastTermination = .now
        if diedRecently {
            tab.loadError = LoadError(url: tab.url, error: NSError(domain: "Browsa", code: 1,
                                                                   userInfo: [NSLocalizedDescriptionKey: "This page keeps crashing."]))
        } else {
            page.reload()
        }
    }

    func page(_ page: any EnginePage, openedPopup popup: any EnginePage, url: URL?) -> (any EnginePageDelegate)? {
        library?.openPopup(from: tab, page: popup, url: url)
    }

    /// A sized popup (a sign-in, usually) gets a small window of its own, as in Safari and Chrome, so the
    /// tab list stays as it was. Anything else becomes a tab under this one.
    func page(_ page: any EnginePage, openedPopup popup: any EnginePage, url: URL?,
              features: PopupFeatures) -> (any EnginePageDelegate)? {
        guard let library else { return nil }
        if features.wantsWindow { return library.openPopupWindow(from: tab, page: popup, features: features) }
        return library.openPopup(from: tab, page: popup, url: url)
    }

    func pageDidRequestClose(_ page: any EnginePage) {
        library?.close(tab)
    }

    func page(_ page: any EnginePage, show dialog: EngineDialog) async -> EngineDialogResponse {
        guard let window else { return .cancel }
        return await window.ask(.dialog(dialog), from: tab)
    }

    func page(_ page: any EnginePage, requestPermission permission: EnginePermission, host: String) async -> Bool {
        guard let library else { return false }
        // Screen sharing is asked every time, like other browsers do.
        let remembers = permission != .screen
        if remembers, tab.isPrivate, let answered = library.privatePermissions[host]?[permission.rawValue] { return answered }
        if remembers, let saved = library.settings.sitePermissions[host]?[permission.rawValue] { return saved }
        guard let window else { return false }
        let answer = await window.ask(.permission(permission, host: host), from: tab)
        // Cancelled because the tab went away: don't remember a "no" the user never gave.
        guard answer != .cancel || window.currentTab?.id == tab.id else { return false }
        let granted = answer == .ok
        // A private tab's answer lasts until the private space closes, and isn't saved.
        if permission == .notifications, granted { SiteNotifications.shared.requestAuthorization(in: window) }
        if remembers {
            if tab.isPrivate {
                library.privatePermissions[host, default: [:]][permission.rawValue] = granted
            } else {
                library.settings.sitePermissions[host, default: [:]][permission.rawValue] = granted
            }
        }
        return granted
    }

    func page(_ page: any EnginePage, trusts certificate: ServerCertificate) -> Bool {
        guard let library else { return false }
        if library.settings.allowLocalCertificateErrors, LocalNetwork.contains(host: certificate.host) { return true }
        if tab.isPrivate, library.privateCertificateExceptions[certificate.site] == certificate.fingerprint { return true }
        return library.settings.certificateExceptions[certificate.site] == certificate.fingerprint
    }

    /// "Visit Anyway" on a certificate error: trust the certificate the site showed, then load it again.
    /// A private tab's exception lasts until the private space closes, and isn't saved.
    func visitAnyway() {
        guard let error = tab.loadError, let fingerprint = error.certificateFingerprint,
              let url = error.url, let host = url.host(), let library else { return }
        let site = ServerCertificate.site(host: host, port: url.port)
        if tab.isPrivate {
            library.privateCertificateExceptions[site] = fingerprint
        } else {
            library.settings.certificateExceptions[site] = fingerprint
        }
        load(url, source: .typed)
    }

    func page(_ page: any EnginePage, showNotification notification: WebNotification) async -> Bool {
        guard !tab.isPrivate else { return false }
        return await SiteNotifications.shared.show(notification, from: tab, in: window ?? library?.activeWindow)
    }

    func page(_ page: any EnginePage, closeNotification id: String, tag: String?) {
        SiteNotifications.shared.close(tab: tab.id, id: id, tag: tag)
    }

    func page(_ page: any EnginePage, chooseFiles request: FileChooserRequest) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = request.allowsMultiple
        panel.canChooseDirectories = request.allowsDirectories
        panel.canChooseFiles = true
        if let window = page.view.window ?? NSApp.keyWindow {
            return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
        }
        return panel.runModal() == .OK ? panel.urls : nil
    }

    func page(_ page: any EnginePage, didStartDownload download: EngineDownload) {
        guard let library else { return }
        library.downloads.insert(download, at: 0)
        (window ?? library.activeWindow)?.showToast("Downloading \(download.filename)")
    }

    func pageDidDeclineCookieBanner(_ page: any EnginePage) {
        guard let browser = window, let url = page.state.url,
              browser.lastCookieToastURL != url else { return }
        browser.lastCookieToastURL = url
        browser.showToast("Cookie banner declined")
    }
}
