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
    private(set) var page: (any EnginePage)!
    private weak var browser: Browser?
    /// How the next finished load should count in history.
    private var pendingSource: Frecency.VisitSource?
    /// The page's process died while it was out of sight. Reload when it's shown again.
    private var needsRecovery = false
    private var lastTermination: Date?

    init(tab: BrowserTab, browser: Browser, makePage: (TabController) -> any EnginePage) {
        self.tab = tab
        self.browser = browser
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
        tab.estimatedProgress = s.progress
        tab.isLoading = s.isLoading
        tab.canGoBack = s.canGoBack
        tab.canGoForward = s.canGoForward
    }

    func load(_ url: URL, source: Frecency.VisitSource) {
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
        browser?.showToast(direction == 0 ? "Actual Size" : "Zoom \(Int((next * 100).rounded()))%")
    }

    // MARK: EnginePageDelegate

    func page(_ page: any EnginePage, decide request: NavigationRequest) async -> NavigationDecision {
        guard let browser else { return .allow }
        if request.wantsNewTab {
            browser.openInNewTab(request.url, from: tab, foreground: request.wantsForeground)
            return .cancel
        }
        let scheme = request.url.scheme?.lowercased() ?? ""
        guard ["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) else {
            // mailto:, zoommtg:, App Store links and the like belong to other apps.
            NSWorkspace.shared.open(request.url)
            return .cancel
        }
        if request.isMainFrame, browser.settings.cleanLinks, request.method == "GET",
           !browser.settings.blockingDisabled(for: request.url.host()),
           let clean = LinkCleaner.clean(request.url) {
            return .redirect(clean)
        }
        return .allow
    }

    func page(_ page: any EnginePage, didCommit url: URL?) {
        tab.loadError = nil
        browser?.cancelPrompts(for: tab.id)
        if let host = url?.host() {
            let z = Preferences.zoom(for: host)
            if abs(page.zoom - z) > 0.001 { page.zoom = z }
        }
    }

    func page(_ page: any EnginePage, didFinish url: URL, title: String) {
        browser?.scheduleSave()
        guard !tab.isPrivate, let history = browser?.history else { pendingSource = nil; return }
        let source = pendingSource ?? .link
        pendingSource = nil
        Task { await history.recordVisit(url: url, title: title, source: source) }
    }

    func page(_ page: any EnginePage, didFailWith error: NSError) {
        let failed = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? page.state.url
        tab.loadError = LoadError(url: failed, error: error)
    }

    func pageContentProcessDidTerminate(_ page: any EnginePage) {
        guard browser?.currentTab?.id == tab.id else { needsRecovery = true; return }
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
        browser?.openPopup(from: tab, page: popup, url: url)
    }

    func pageDidRequestClose(_ page: any EnginePage) {
        browser?.close(tab)
    }

    func page(_ page: any EnginePage, show dialog: EngineDialog) async -> EngineDialogResponse {
        guard let browser else { return .cancel }
        return await browser.ask(.dialog(dialog), from: tab)
    }

    func page(_ page: any EnginePage, requestPermission permission: EnginePermission, host: String) async -> Bool {
        guard let browser else { return false }
        if let saved = browser.settings.sitePermissions[host]?[permission.rawValue] { return saved }
        let answer = await browser.ask(.permission(permission, host: host), from: tab)
        guard answer != .cancel || browser.currentTab?.id == tab.id else { return false }
        let granted = answer == .ok
        browser.settings.sitePermissions[host, default: [:]][permission.rawValue] = granted
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
        guard let browser else { return }
        browser.downloads.insert(download, at: 0)
        browser.showToast("Downloading \(download.filename)")
    }

    func pageDidDeclineCookieBanner(_ page: any EnginePage) {
        guard let browser, browser.currentTab?.id == tab.id, let url = page.state.url,
              browser.lastCookieToastURL != url else { return }
        browser.lastCookieToastURL = url
        browser.showToast("Cookie banner declined")
    }
}
