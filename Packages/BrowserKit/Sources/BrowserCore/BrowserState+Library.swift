#if os(iOS)
import Foundation
import UIKit
import WebKit
import Suggest

extension BrowserState {
    // MARK: Website data

    /// Forgets cookies and site storage from regular tabs. Private tabs have their own store.
    public func clearWebsiteData() async {
        await WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                      modifiedSince: .distantPast)
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        // The open page still looks signed in until it's loaded again.
        if currentTab?.isPrivate == false { reload() }
    }

    // MARK: Spaces

    public func addSpace() {
        let used = Set(spaces.map(\.colorIndex))
        let color = (0..<6).first { !used.contains($0) } ?? spaces.count
        let space = Space(name: "Space \(regularSpaces.count + 1)", symbol: "circle.fill", colorIndex: color)
        // Private stays at the end.
        spaces.insert(space, at: spaces.firstIndex { $0.isPrivate } ?? spaces.endIndex)
        scheduleSave()
    }

    public func deleteSpace(_ space: Space) {
        if space.isPrivate { closePrivateSpace(); return }
        guard regularSpaces.count > 1, let i = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        space.allTabs.forEach { pool.remove($0.id) }
        spaces.remove(at: i)
        if selectedSpaceID == space.id { selectedSpaceID = regularSpaces[0].id }
        if settings.externalLinksSpaceID == space.id { settings.externalLinksSpaceID = nil }
        scheduleSave()
    }

    /// A link opened from another app (once this is the default browser).
    public func openExternal(_ url: URL) {
        // Never into Private: links from other apps belong with your normal tabs.
        let target = regularSpaces.first { $0.id == settings.externalLinksSpaceID } ?? regularTargetSpace
        isNewTabSheetPresented = false
        newTab(url: url, in: target, source: .link)
    }

    // MARK: Archive

    public func restoreFromArchive(_ tab: BrowserTab) {
        archive.removeAll { $0.id == tab.id }
        tab.lastActive = .now
        regularTargetSpace.today.insert(tab, at: 0)
        select(tab)
    }

    public func clearArchive() {
        archive.removeAll()
        scheduleSave()
    }

    // MARK: Saved sites

    public func isSaved(_ url: URL) -> Bool {
        let key = URLNormalizer.key(for: url)
        return saved.contains { URLNormalizer.key(for: $0.url) == key }
    }

    /// The page menu's Save / Unsave for the current page. Keeps a picture of the page for the list.
    public func toggleSavedForCurrentTab() {
        guard let tab = currentTab, let url = tab.url else { return }
        let key = URLNormalizer.key(for: url)
        if let existing = saved.first(where: { URLNormalizer.key(for: $0.url) == key }) {
            removeSaved(existing)
            showToast("Removed from Saved")
            return
        }
        let site = SavedSite(url: url, title: tab.displayTitle)
        saved.insert(site, at: 0)
        if let image = pool.existingSession(for: tab.id)?.renderThumbnail() ?? thumbnails[tab.id] {
            thumbnails[site.id] = image
            // A private page's picture stays in memory, like private tabs' own.
            if !tab.isPrivate, let thumbnailStore, let data = image.jpegData(compressionQuality: 0.7) {
                let id = site.id
                Task.detached(priority: .utility) { thumbnailStore.save(data, for: id) }
            }
        }
        showToast("Saved")
        scheduleSave()
    }

    public func removeSaved(_ site: SavedSite) {
        saved.removeAll { $0.id == site.id }
        thumbnails[site.id] = nil
        if let thumbnailStore {
            let id = site.id
            Task.detached(priority: .utility) { thumbnailStore.remove(id) }
        }
        scheduleSave()
    }

    // MARK: Favourites

    public func isFavorite(_ url: URL) -> Bool {
        let key = URLNormalizer.key(for: url)
        return favorites.contains { URLNormalizer.key(for: $0.url) == key }
    }

    public func addFavorite(url: URL, title: String) {
        guard !isFavorite(url) else { return }
        favorites.append(Favorite(url: url, title: title, order: (favorites.map(\.order).max() ?? -1) + 1))
        Task { await history.setBookmarked(url, true) }
        scheduleSave()
    }

    public func removeFavorite(_ fav: Favorite) {
        favorites.removeAll { $0.id == fav.id }
        Task { await history.setBookmarked(fav.url, false) }
        scheduleSave()
    }

    public func renameFavorite(_ fav: Favorite, to name: String) {
        guard let i = favorites.firstIndex(where: { $0.id == fav.id }) else { return }
        favorites[i].customName = name.isEmpty ? nil : name
        scheduleSave()
    }

    public func moveFavorites(fromOffsets: IndexSet, toOffset: Int) {
        var sorted = favorites.sorted { $0.order < $1.order }
        sorted.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for i in sorted.indices { sorted[i].order = i }
        favorites = sorted
        scheduleSave()
    }
}
#endif
