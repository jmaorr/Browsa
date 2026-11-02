#if os(iOS)
import Foundation
import WebKit

/// Keeps at most `capacity` live web views. Least-recently-used sessions are frozen
/// (interactionState saved) and released; selecting their tab rebuilds them.
@MainActor
final class WebViewPool {
    let capacity: Int
    private(set) var sessions: [UUID: TabSession] = [:]
    private var lru: [UUID] = []
    private var contentRulesReady = false
    private var loadsWaitingForContentRules: [() -> Void] = []

    let configuration: WKWebViewConfiguration
    /// Shared by every private tab, so they share a sign-in, like Safari's private tabs.
    /// Its data store is replaced when the last private tab closes, which throws its cookies and storage away.
    let privateConfiguration: WKWebViewConfiguration

    init(capacity: Int = 6) {
        self.capacity = capacity
        configuration = Self.makeConfiguration(store: .default())
        privateConfiguration = Self.makeConfiguration(store: .nonPersistent())
    }

    static func makeConfiguration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = store
        c.allowsInlineMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = .all
        c.upgradeKnownHostsToHTTPS = true
        c.defaultWebpagePreferences.preferredContentMode = .mobile
        c.preferences.isElementFullscreenEnabled = true
        // Videos can float in picture-in-picture when you leave the page or the app.
        c.allowsPictureInPictureMediaPlayback = true
        c.allowsAirPlayForMediaPlayback = true
        // Say "Safari" like Safari does. WKWebView's default user agent leaves out the
        // "Version/… Safari/…" tokens, and some sites (Google among them) then serve older,
        // plainer pages or warn that the browser isn't supported.
        c.applicationNameForUserAgent = SafariUserAgent.mobileApplicationName
        return c
    }

    func session(for tab: BrowserTab, browser: BrowserState) -> TabSession {
        touch(tab.id)
        if let s = sessions[tab.id] { return s }
        let s = TabSession(tab: tab, configuration: tab.isPrivate ? privateConfiguration : configuration,
                           browser: browser)
        sessions[tab.id] = s
        evictIfNeeded(keeping: tab.id)
        return s
    }

    /// Runs `load` once the content rule lists are installed, so a tab restored at launch can't
    /// slip through unblocked while they're still being looked up.
    func afterContentRules(_ load: @escaping () -> Void) {
        if contentRulesReady { load(); return }
        loadsWaitingForContentRules.append(load)
        // Compiling can take a while on a phone. A page without blocking beats a blank one.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.markContentRulesReady()
        }
    }

    func markContentRulesReady() {
        contentRulesReady = true
        let waiting = loadsWaitingForContentRules
        loadsWaitingForContentRules = []
        waiting.forEach { $0() }
    }

    /// Registers a session created by WebKit for a popup (window.open).
    func adopt(_ session: TabSession) {
        sessions[session.tab.id] = session
        touch(session.tab.id)
        evictIfNeeded(keeping: session.tab.id)
    }

    func existingSession(for id: UUID) -> TabSession? { sessions[id] }

    func remove(_ id: UUID) {
        sessions[id]?.webView.stopLoading()
        sessions[id] = nil
        lru.removeAll { $0 == id }
    }

    /// The Private space closed: forget everything its tabs stored.
    func resetPrivateStore() {
        for (id, s) in sessions where s.tab.isPrivate { remove(id) }
        // Web views copy the configuration when they're made, so the next private tab gets a
        // fresh store and keeps the same blockers and scripts.
        privateConfiguration.websiteDataStore = .nonPersistent()
    }

    func freezeAll() {
        sessions.values.forEach { $0.freeze() }
    }

    private func touch(_ id: UUID) {
        lru.removeAll { $0 == id }
        lru.append(id)
    }

    private func evictIfNeeded(keeping id: UUID) {
        while lru.count > capacity, let victim = lru.first(where: { $0 != id }) {
            sessions[victim]?.freeze()
            remove(victim)
        }
    }
}
/// User agent strings that match Safari on this OS version.
enum SafariUserAgent {
    static var version: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    /// Appended to WebKit's mobile UA ("Mozilla/5.0 (iPhone; …) AppleWebKit/605.1.15 (KHTML, like Gecko)").
    static var mobileApplicationName: String { "Version/\(version) Mobile/15E148 Safari/604.1" }

    /// What Safari sends when it asks for the desktop site (the same as Safari on a Mac).
    static var desktop: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }
}
#endif
