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

    let configuration: WKWebViewConfiguration
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
        return c
    }

    func session(for tab: Tab, browser: BrowserState) -> TabSession {
        touch(tab.id)
        if let s = sessions[tab.id] { return s }
        let s = TabSession(tab: tab, configuration: tab.isPrivate ? privateConfiguration : configuration,
                           browser: browser)
        sessions[tab.id] = s
        evictIfNeeded(keeping: tab.id)
        return s
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
#endif
