import AppKit
import BrowserCore
import BrowserEngine

/// Call tabs: Meet, Zoom and Teams run on Chromium inside an ordinary Browsa tab, because Chromium
/// plays a call's audio and captures the mic itself, with its echo canceller in between (WebKit can't
/// hand Browsa what it plays, so people on calls heard themselves). Everything else stays on WebKit.
@MainActor
enum CallTabs {
    /// Sites that run in Chromium.
    static let callHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"]
    /// Sign-in and helper pages a call site sends you through. A call tab stays on Chromium for these
    /// (so the sign-in lands in Chromium's cookies), but they don't pull an ordinary tab over.
    static let callAdjacentHosts = ["accounts.google.com", "google.com", "gstatic.com", "googleusercontent.com",
                                    "microsoftonline.com", "login.live.com", "microsoft.com", "office.com", "office.net",
                                    "microsoft365.com", "cloud.microsoft", "live.com", "skype.com", "msauth.net",
                                    "zoom.com", "zoomgov.com"]
    /// Sign-in pages a call site opens in a pop-up window, which has to report back to it.
    static let signInHosts = ["accounts.google.com", "microsoftonline.com", "login.live.com", "login.microsoft.com",
                              "msauth.net", "zoom.us", "zoom.com"]

    static func matches(_ host: String, _ list: [String]) -> Bool {
        let h = host.lowercased()
        return list.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    static func isCallSite(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host() else { return false }
        return matches(host, callHosts + testHosts)
    }

    /// Debug builds: BROWSA_CALL_TEST_HOSTS=localhost,… routes test pages to Chromium too.
    static let testHosts: [String] = {
        #if DEBUG
        ProcessInfo.processInfo.environment["BROWSA_CALL_TEST_HOSTS"]?.split(separator: ",").map(String.init) ?? []
        #else
        []
        #endif
    }()

    static func staysInCallTab(_ url: URL?) -> Bool {
        guard let url else { return false }
        if isCallSite(url) { return true }
        guard let host = url.host() else { return url.scheme == "about" || url.scheme == "data" || url.scheme == "blob" }
        return matches(host, callAdjacentHosts)
    }

    /// Tabs the user moved with Open in Chromium / Open in WebKit, until they navigate elsewhere.
    static var forced: [UUID: String] = [:]

    static func install(in library: Library) {
        let chromium = ChromiumEngine.shared
        library.engineChooser = { [weak library] tab, url in
            guard let library else { return chromium }
            if let id = forced[tab.id] { return id == chromium.info.id && available(in: library) ? chromium : library.engine }
            if isCallSite(url) { return available(in: library) ? chromium : library.engine }
            let current = library.existingController(for: tab)?.engineID
            if current == chromium.info.id, staysInCallTab(url) { return chromium }
            return library.engine
        }
        library.closeGuard = { [weak library] tab in
            guard let library else { return true }
            let inCall = tabsInCall(in: library).filter { $0.id == tab.id }
            return confirmLeaving(inCall, quitting: false)
        }
        // A call tab that follows a link off the call site (and its sign-in pages) hands the tab back to
        // WebKit. Redirects and the site's own navigations stay put.
        ChromiumPage.navigationGate = { [weak library] page, url, userGesture in
            guard let library, userGesture, !staysInCallTab(url),
                  let tab = library.allTabs.first(where: { library.existingController(for: $0)?.page === page }) else { return true }
            forced[tab.id] = nil
            DispatchQueue.main.async { library.swapEngine(of: tab, to: url) }
            return false
        }
    }

    /// Whether Chromium can run (it starts here, with the first call tab). If it can't, call sites open
    /// on WebKit as before, with one notice per launch.
    private static var toldUnavailable = false
    static func available(in library: Library) -> Bool {
        if ChromiumEngine.shared.startIfNeeded() { return true }
        if !toldUnavailable {
            toldUnavailable = true
            library.activeWindow?.showToast("Calls open in a normal tab: Browsa's Chromium for calls didn't start")
        }
        return false
    }

    // MARK: Calls in progress

    /// Tabs whose page is using the mic or camera right now.
    static func tabsInCall(in library: Library) -> [BrowserTab] {
        library.allTabs.filter { (library.existingController(for: $0)?.page as? ChromiumPage)?.isInCall == true }
    }

    /// Before closing a tab that's in a call: asks. True to go ahead.
    static func confirmLeaving(_ tabs: [BrowserTab], quitting: Bool) -> Bool {
        guard let tab = tabs.first else { return true }
        let alert = NSAlert()
        let name = tab.title.isEmpty ? (tab.url?.host() ?? "a call") : tab.title
        alert.messageText = quitting ? "You're on a call. Quit Browsa?" : "Leave the call?"
        alert.informativeText = quitting
            ? "\(name) is using your microphone or camera. Quitting ends the call."
            : "\(name) is using your microphone or camera. Closing the tab ends the call."
        alert.addButton(withTitle: quitting ? "Quit" : "Leave Call")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Open in Chromium / Open in WebKit for the current tab.
    static func move(_ tab: BrowserTab, toChromium: Bool, in library: Library) {
        guard let url = tab.url else { return }
        forced[tab.id] = toChromium ? ChromiumEngine.shared.info.id : library.engine.info.id
        library.swapEngine(of: tab, to: url, source: .reload)
    }
}
