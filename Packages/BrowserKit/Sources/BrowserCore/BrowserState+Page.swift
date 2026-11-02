#if os(iOS)
import Foundation
import UIKit
import WebKit
import Suggest

extension BrowserState {
    // MARK: Links

    /// Long-press > Open in Background: a new today tab right after the opener, loading quietly.
    public func openInBackground(_ url: URL, from opener: BrowserTab?) {
        let space = opener.flatMap { o in spaces.first { $0.allTabs.contains { $0.id == o.id } } } ?? currentSpace
        let tab = BrowserTab(url: url, isPrivate: opener?.isPrivate ?? false)
        let after = opener.flatMap { o in space.today.firstIndex { $0.id == o.id } }.map { $0 + 1 } ?? 0
        space.today.insert(tab, at: after)
        session(for: tab).load(url, source: .link)
        // Loading made it most-recently-used in the pool; the visible tab must stay ahead of it.
        if let current = currentTab { _ = session(for: current) }
        showToast("Opened in background")
        scheduleSave()
    }

    public func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Desktop / mobile sites

    /// Desktop on the inner display, mobile on the outer, unless the site has an override.
    func prefersDesktop(for url: URL?) -> Bool {
        if let host = url.map(URLNormalizer.displayHost), let o = settings.siteDesktopOverrides[host] { return o }
        return isUnfolded && settings.desktopSitesWhenUnfolded
    }

    /// "Request Desktop Site" / "Request Mobile Site": remembered for the site, page reloads.
    public func toggleDesktopSite() {
        guard let tab = currentTab, let url = tab.url else { return }
        let host = URLNormalizer.displayHost(url)
        let wantDesktop = !tab.isDesktopSite
        // Store an override only when it differs from what the posture would pick anyway.
        let natural = isUnfolded && settings.desktopSitesWhenUnfolded
        settings.siteDesktopOverrides[host] = wantDesktop == natural ? nil : wantDesktop
        // reloadFromOrigin re-runs the navigation policy, so the new content mode applies.
        session(for: tab).webView.reloadFromOrigin()
    }

    // MARK: Current page actions

    public func goBack() { currentTab.map { session(for: $0).webView.goBack() } }
    public func goForward() { currentTab.map { session(for: $0).webView.goForward() } }
    public func reload() { currentTab.map { session(for: $0).webView.reload() } }
    public func stopLoading() { currentTab.map { session(for: $0).webView.stopLoading() } }

    /// Cmd-F: the system find bar (same one Safari uses), which sits above the keyboard.
    public func findInPage() {
        guard let tab = currentTab, tab.url != nil else { return }
        session(for: tab).webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    /// Cmd-D: toggles the current page in favourites.
    public func toggleFavoriteForCurrentTab() {
        guard let tab = currentTab, let url = tab.url else { return }
        let key = URLNormalizer.key(for: url)
        if let f = favorites.first(where: { URLNormalizer.key(for: $0.url) == key }) { removeFavorite(f) }
        else { addFavorite(url: url, title: tab.displayTitle) }
    }

    public func togglePinned(_ tab: BrowserTab) {
        let space = spaces.first { $0.allTabs.contains { $0.id == tab.id } } ?? currentSpace
        if tab.isPinned {
            space.pinned.removeAll { $0.id == tab.id }
            space.today.insert(tab, at: 0)
        } else {
            space.today.removeAll { $0.id == tab.id }
            space.pinned.append(tab)
        }
        tab.isPinned.toggle()
        scheduleSave()
    }

    /// Call on launch and when returning to the foreground.
    public func archiveStaleTabs(now: Date = .now) {
        for space in spaces {
            let stale = space.today.filter { $0.id != space.selectedTabID && now.timeIntervalSince($0.lastActive) > settings.archiveAfterHours * 3600 }
            guard !stale.isEmpty else { continue }
            space.today.removeAll { t in stale.contains { $0.id == t.id } }
            stale.forEach { pool.existingSession(for: $0.id)?.freeze(); pool.remove($0.id) }
            archive.insert(contentsOf: stale.filter { !$0.isPrivate }, at: 0)
        }
        archive = Array(archive.prefix(500))
        scheduleSave()
    }
}
#endif
