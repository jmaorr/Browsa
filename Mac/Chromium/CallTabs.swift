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
                                    "login.microsoftonline.com", "login.live.com", "microsoft.com", "office.com",
                                    "live.com", "skype.com", "zoom.com", "zoomgov.com"]

    static func matches(_ host: String, _ list: [String]) -> Bool {
        let h = host.lowercased()
        return list.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    static func isCallSite(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host() else { return false }
        return matches(host, callHosts)
    }

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
            if let id = forced[tab.id] { return id == chromium.info.id ? chromium : library.engine }
            if isCallSite(url) { return chromium }
            let current = library.existingController(for: tab)?.engineID
            if current == chromium.info.id, staysInCallTab(url) { return chromium }
            return library.engine
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

    /// Open in Chromium / Open in WebKit for the current tab.
    static func move(_ tab: BrowserTab, toChromium: Bool, in library: Library) {
        guard let url = tab.url else { return }
        forced[tab.id] = toChromium ? ChromiumEngine.shared.info.id : library.engine.info.id
        library.swapEngine(of: tab, to: url, source: .reload)
    }
}
