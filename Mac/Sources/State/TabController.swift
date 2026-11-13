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
        if let host = tab.url?.host() { page.zoom = Preferences.zoom(for: host) }
        mirror()
    }

    /// Copies the page's live state onto the tab whenever it changes.
    private func mirror() {
        guard let page else { return }
        withObservationTracking {
            let s = page.state
            _ = (s.url, s.title, s.progress, s.isLoading, s.canGoBack, s.canGoForward, s.isSecure)
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
        page.zoom = next
        if let host = tab.url?.host() { Preferences.setZoom(next, for: host) }
        window?.showToast(direction == 0 ? "Actual Size" : "Zoom \(Int((next * 100).rounded()))%")
    }

    // MARK: EnginePageDelegate

    func page(_ page: any EnginePage, decide request: NavigationRequest) async -> NavigationDecision {
        guard let library else { return .allow }
        if request.wantsNewTab {
            library.openInNewTab(request.url, from: tab, foreground: request.wantsForeground)
            return .cancel
        }
        let scheme = request.url.scheme?.lowercased() ?? ""
        guard ["http", "https", "about", "blob", "data", "file", "javascript", "webkit-extension"].contains(scheme) else {
            // mailto:, zoommtg:, App Store links and the like belong to other apps. Browsa asks first (as
            // Chrome does), so a page can't throw you into an app: Zoom's join page fires zoommtg: on its
            // own, and saying no keeps its "join from your browser" option. Email links just open.
            Task { await openInApp(request.url) }
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

    private func openInApp(_ url: URL) async {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["mailto", "tel", "facetime", "sms"].contains(scheme) { NSWorkspace.shared.open(url); return }
        guard let window else { return }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let host = page.state.url?.host() ?? tab.url?.host() ?? ""
        let answer = await window.ask(.dialog(.confirm(host: host, message: "Open \(name)? This page wants to open a link in \(name).")), from: tab)
        if answer == .ok { NSWorkspace.shared.open(url) }
    }

    func page(_ page: any EnginePage, didCommit url: URL?) {
        tab.loadError = nil
        library?.windows.forEach { $0.cancelPrompts(for: tab.id) }
        if let host = url?.host() {
            let z = Preferences.zoom(for: host)
            if abs(page.zoom - z) > 0.001 { page.zoom = z }
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
        if remembers, let saved = library.settings.sitePermissions[host]?[permission.rawValue] { return saved }
        guard let window else { return false }
        let answer = await window.ask(.permission(permission, host: host), from: tab)
        // Cancelled because the tab went away: don't remember a "no" the user never gave.
        guard answer != .cancel || window.currentTab?.id == tab.id else { return false }
        let granted = answer == .ok
        if remembers { library.settings.sitePermissions[host, default: [:]][permission.rawValue] = granted }
        return granted
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
