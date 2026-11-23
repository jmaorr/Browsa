import Foundation
import BrowserCore

/// Folders among a space's pinned tabs, like Arc's (see `PinnedOutline`). Every change goes
/// through `setPinnedLayout`, which also puts `space.pinned` in the order the sidebar shows, so
/// ⌘1…⌘9 and next/previous tab follow what you see.
extension Library {
    func setPinnedLayout(_ layout: [PinnedNode], in space: Space) {
        let tree = PinnedOutline.reconciled(layout, tabs: space.pinned.map(\.id))
        space.pinnedLayout = tree
        let byID = Dictionary(space.pinned.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = PinnedOutline.tabIDs(tree).compactMap { byID[$0] }
        if ordered.map(\.id) != space.pinned.map(\.id) { space.pinned = ordered }
        scheduleSave()
    }

    /// A new folder, at `place` (the top of the pinned section by default), holding `tab` if given.
    /// Returns its id so the sidebar can start renaming it.
    @discardableResult
    func newPinnedFolder(in space: Space, at place: PinnedPlace? = nil, holding tab: BrowserTab? = nil,
                         name: String = "New Folder") -> UUID? {
        guard !space.isPrivate else { return nil }
        if let tab, !tab.isPinned || self.space(containing: tab)?.id != space.id {
            pin(tab, in: space, at: PinnedPlace(parent: nil, index: 0))
        }
        var tree = space.pinnedTree
        var place = place ?? PinnedPlace(parent: nil, index: 0)
        if let tab, let at = PinnedOutline.place(of: tab.id, in: tree) {
            // The folder takes the tab's spot, and the tab goes in it.
            place = at
            tree = PinnedOutline.removing(tab.id, from: tree).0
        }
        let folder = PinnedFolder(name: name, isOpen: true, children: tab.map { [.tab($0.id)] } ?? [])
        setPinnedLayout(PinnedOutline.inserting(.folder(folder), at: place, in: tree), in: space)
        return folder.id
    }

    func renamePinnedFolder(_ id: UUID, to name: String, in space: Space) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        setPinnedLayout(PinnedOutline.updating(id, in: space.pinnedTree) { $0.name = name }, in: space)
    }

    func setPinnedFolder(_ id: UUID, open: Bool, in space: Space) {
        setPinnedLayout(PinnedOutline.updating(id, in: space.pinnedTree) { $0.isOpen = open }, in: space)
    }

    /// Takes the folder away. What it held stays pinned, where the folder was.
    func removePinnedFolder(_ id: UUID, in space: Space) {
        setPinnedLayout(PinnedOutline.dissolving(id, in: space.pinnedTree), in: space)
    }

    /// Moves a pinned tab or folder that's already in `space` to `place`.
    func movePinned(_ id: UUID, to place: PinnedPlace, in space: Space) {
        setPinnedLayout(PinnedOutline.moving(id, to: place, in: space.pinnedTree), in: space)
    }

    /// Pins `tab` in `space` at `place`, from wherever it was: Today, a favourite's tile, another
    /// space, or elsewhere among the pinned.
    func pin(_ tab: BrowserTab, in space: Space, at place: PinnedPlace) {
        guard !tab.isPrivate, !space.isPrivate else { return }
        if !tab.isPinned || self.space(containing: tab)?.id != space.id {
            tab.favoriteID = nil
            move(tab, before: nil, pinned: true, fallback: space)
        }
        guard self.space(containing: tab)?.id == space.id else { return }
        movePinned(tab.id, to: place, in: space)
    }
}
