#if os(iOS)
import Foundation
import UIKit
import WebKit
import Suggest

extension BrowserState {
    // MARK: Spaces

    public func addSpace() {
        let used = Set(spaces.map(\.colorIndex))
        let color = (0..<6).first { !used.contains($0) } ?? spaces.count
        let space = Space(name: "Space \(spaces.count + 1)", symbol: "circle.fill", colorIndex: color)
        spaces.append(space)
        scheduleSave()
    }

    public func deleteSpace(_ space: Space) {
        guard spaces.count > 1, let i = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        space.allTabs.forEach { pool.remove($0.id) }
        spaces.remove(at: i)
        if selectedSpaceID == space.id { selectedSpaceID = spaces[0].id }
        if settings.externalLinksSpaceID == space.id { settings.externalLinksSpaceID = nil }
        scheduleSave()
    }

    /// A link opened from another app (once this is the default browser).
    public func openExternal(_ url: URL) {
        let target = spaces.first { $0.id == settings.externalLinksSpaceID } ?? currentSpace
        isNewTabSheetPresented = false
        newTab(url: url, in: target, source: .link)
    }

    // MARK: Archive

    public func restoreFromArchive(_ tab: BrowserTab) {
        archive.removeAll { $0.id == tab.id }
        tab.lastActive = .now
        currentSpace.today.insert(tab, at: 0)
        select(tab)
    }

    public func clearArchive() {
        archive.removeAll()
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
