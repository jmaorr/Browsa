import Foundation
import Observation
import SwiftUI
import BrowserCore

/// Split View, like Arc's: two or three tabs side by side in the page column, kept together as one
/// row in the sidebar.
///
/// A split is only a list of tab ids. The tabs stay ordinary tabs in their space's Pinned or Today
/// list, side by side, so everything that works on a tab (closing, moving, archiving, the iPhone's
/// copy of the state) keeps working. A split whose tabs have gone, moved apart or dropped below two
/// is simply no longer a split.
///
/// Kept in the Mac's own preferences rather than the shared browser state, which the iPhone reads too.
@MainActor @Observable
final class SplitStore {
    struct Group: Codable, Identifiable, Equatable {
        var id = UUID()
        /// Left to right.
        var tabIDs: [UUID]
        /// Each pane's share of the width, by tab. Missing ones count as equal shares.
        var widths: [UUID: Double] = [:]
    }

    /// Arc allows more, but past three panes a laptop screen has no room left for any of them.
    static let maxPanes = 3

    private(set) var groups: [Group] { didSet { if groups != oldValue { save() } } }

    private static let key = "splitViews"

    init() {
        groups = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([Group].self, from: $0) } ?? []
    }

    func group(containing tabID: UUID) -> Group? {
        groups.first { $0.tabIDs.contains(tabID) }
    }

    /// Adds `tabID` to `anchorID`'s split, making one if there isn't one yet. It leaves any split it was in.
    func join(_ tabID: UUID, to anchorID: UUID) {
        guard tabID != anchorID else { return }
        remove(tabID)
        if let i = groups.firstIndex(where: { $0.tabIDs.contains(anchorID) }) {
            guard groups[i].tabIDs.count < Self.maxPanes else { return }
            groups[i].tabIDs.append(tabID)
            // The new pane takes an equal share; the others give it up in proportion.
            groups[i].widths = [:]
        } else {
            groups.append(Group(tabIDs: [anchorID, tabID]))
        }
    }

    /// Takes a tab out of its split. A split left with one tab ends.
    func remove(_ tabID: UUID) {
        guard let i = groups.firstIndex(where: { $0.tabIDs.contains(tabID) }) else { return }
        groups[i].tabIDs.removeAll { $0 == tabID }
        groups[i].widths[tabID] = nil
        if groups[i].tabIDs.count < 2 { groups.remove(at: i) }
    }

    /// Ends the split a tab is in. Its tabs stay open.
    func dissolve(containing tabID: UUID) {
        groups.removeAll { $0.tabIDs.contains(tabID) }
    }

    /// Moves a pane one place left (-1) or right (+1).
    func shift(_ tabID: UUID, by delta: Int) {
        guard let g = groups.firstIndex(where: { $0.tabIDs.contains(tabID) }),
              let i = groups[g].tabIDs.firstIndex(of: tabID) else { return }
        let j = i + delta
        guard groups[g].tabIDs.indices.contains(j) else { return }
        groups[g].tabIDs.swapAt(i, j)
    }

    func setWidths(_ widths: [UUID: Double], containing tabID: UUID) {
        guard let i = groups.firstIndex(where: { $0.tabIDs.contains(tabID) }) else { return }
        groups[i].widths = widths
    }

    /// Keeps only the splits that still have two or more tabs `isLive` accepts, with those tabs.
    func prune(isLive: ([UUID]) -> [UUID]) {
        var kept: [Group] = []
        for var g in groups {
            g.tabIDs = isLive(g.tabIDs)
            g.widths = g.widths.filter { g.tabIDs.contains($0.key) }
            if g.tabIDs.count > 1 { kept.append(g) }
        }
        if kept != groups { groups = kept }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(groups), forKey: Self.key)
    }
}

// MARK: - Library

extension Library {
    /// The tabs of the split `tab` is in, left to right, or nil when it isn't in one. Only tabs still
    /// in the same space and the same list as each other count, and a favourite's own tab never does.
    func splitTabs(of tab: BrowserTab) -> [BrowserTab]? {
        guard let group = splits.group(containing: tab.id) else { return nil }
        let live = liveSplitTabs(group.tabIDs)
        return live.count > 1 && live.contains(where: { $0.id == tab.id }) ? live : nil
    }

    /// The tabs of a split that still belong together: in the space and list of the first one found.
    private func liveSplitTabs(_ ids: [UUID]) -> [BrowserTab] {
        let tabs = ids.compactMap { id in spaces.lazy.compactMap { s in s.allTabs.first { $0.id == id } }.first }
            .filter { $0.favoriteID == nil }
        guard let first = tabs.first, let home = space(containing: first) else { return [] }
        return tabs.filter { $0.isPinned == first.isPinned && space(containing: $0)?.id == home.id }
    }

    /// Forgets splits whose tabs have closed, been archived or moved apart. Run with each save.
    func pruneSplits() {
        splits.prune { ids in liveSplitTabs(ids).map(\.id) }
    }
}

// MARK: - Browser

extension Browser {
    /// The split the current tab is in, as this window lists it, or nil.
    var splitTabs: [BrowserTab]? {
        guard let current = currentTab, let tabs = library.splitTabs(of: current) else { return nil }
        // Never a tab another window has on screen by itself: a page can only be in one place.
        let others = library.windows.filter { $0 !== self }.compactMap { $0.currentTab?.id }
        let shown = tabs.filter { $0.id == current.id || (lists($0) && !others.contains($0.id)) }
        return shown.count > 1 ? shown : nil
    }

    /// The tabs this window has on screen: the current one, and the rest of its split.
    var shownTabs: [BrowserTab] { splitTabs ?? currentTab.map { [$0] } ?? [] }

    var shownTabIDs: Set<UUID> { Set(shownTabs.map(\.id)) }

    var isSplit: Bool { splitTabs != nil }

    /// Each pane's share of the width, adding up to 1.
    func splitWidths(_ tabs: [BrowserTab]) -> [Double] {
        let saved = tabs.first.flatMap { library.splits.group(containing: $0.id) }?.widths ?? [:]
        let raw = tabs.map { max(0.05, saved[$0.id] ?? 1 / Double(tabs.count)) }
        let total = raw.reduce(0, +)
        return raw.map { $0 / total }
    }

    func setSplitWidths(_ widths: [Double], for tabs: [BrowserTab]) {
        guard let first = tabs.first else { return }
        library.splits.setWidths(Dictionary(uniqueKeysWithValues: zip(tabs.map(\.id), widths)), containing: first.id)
    }

    /// Whether `tab` could join the split on screen (or start one with the current tab).
    func canSplit(with tab: BrowserTab) -> Bool {
        guard let current = currentTab, tab.id != current.id, tab.isPrivate == current.isPrivate,
              !Welcome.isWelcome(current.url), !Welcome.isWelcome(tab.url) else { return false }
        let shown = shownTabs
        return shown.count < SplitStore.maxPanes && !shown.contains { $0.id == tab.id }
    }

    /// Puts `tab` beside what's on screen, as a new pane on the right, and moves to it. Its row joins
    /// the split's in the sidebar: the tab moves next to the others, into their list and space.
    func openInSplit(_ tab: BrowserTab) {
        guard canSplit(with: tab), let current = currentTab, let space = space(containing: current) else { return }
        let panes = shownTabs
        // A favourite's own tab leaves its tile to join: a split lives in the tab list.
        for t in panes + [tab] where t.favoriteID != nil { t.favoriteID = nil }
        library.splits.remove(tab.id)
        // A split that only lived in this window's eyes (its other tabs elsewhere) starts again from what's shown.
        if panes.count == 1 { library.splits.remove(current.id) }
        let last = panes.last ?? current
        let list = last.isPinned ? space.pinned : today(in: space)
        let after = list.firstIndex { $0.id == last.id }.flatMap { i in list[(i + 1)...].first { $0.id != tab.id } }
        library.move(tab, before: after, pinned: last.isPinned, fallback: space)
        if !tab.isPinned { tab.windowKey = windowKey }
        library.splits.join(tab.id, to: current.id)
        // Every pane of a split is shown together, so they all count as used now.
        for t in shownTabs { t.lastActive = .now }
        select(tab)
        scheduleSave()
    }

    /// ⌃⇧=: a new, empty pane beside what's on screen, with the address bar open to fill it.
    func newSplitPane() {
        guard let current = currentTab, let space = space(containing: current), !Welcome.isWelcome(current.url) else { return }
        guard shownTabs.count < SplitStore.maxPanes else {
            showToast("Split View holds up to \(SplitStore.maxPanes) tabs")
            return
        }
        let tab = newTab(url: nil, in: space, isPrivate: current.isPrivate, select: false)
        openInSplit(tab)
        showCommandBar(.editCurrent)
    }

    /// Opens what the Glance shows as a pane beside the page, instead of a tab of its own.
    func expandGlanceIntoSplit() {
        guard let g = glance, let url = g.url, let current = currentTab else { return }
        closeGlance()
        let tab = newTab(url: url, in: space(containing: current), isPrivate: g.isPrivate, source: .link, select: false)
        if canSplit(with: tab) { openInSplit(tab) } else { select(tab) }
    }

    /// Takes a tab out of its split. It stays open, as its own row, just below.
    func removeFromSplit(_ tab: BrowserTab) {
        let wasShown = shownTabIDs.contains(tab.id)
        let mates = library.splitTabs(of: tab)?.filter { $0.id != tab.id } ?? []
        library.splits.remove(tab.id)
        // The page that stays is the one beside it, unless the tab itself was in front.
        if wasShown, currentTab?.id == tab.id, let next = mates.first { select(next) }
        scheduleSave()
    }

    /// Ends the split a tab is in. Every tab stays open, the one in front still showing.
    func separateSplit(containing tab: BrowserTab) {
        library.splits.dissolve(containing: tab.id)
        scheduleSave()
    }

    /// Closes every tab in a split (unloads, if pinned).
    func closeSplit(containing tab: BrowserTab) {
        let tabs = library.splitTabs(of: tab) ?? [tab]
        library.splits.dissolve(containing: tab.id)
        for t in tabs { close(t) }
    }

    /// Moves a pane one place left or right.
    func shiftPane(_ tab: BrowserTab, by delta: Int) {
        library.splits.shift(tab.id, by: delta)
    }

    /// Gives every pane the same width.
    func evenSplit(_ tabs: [BrowserTab]) {
        setSplitWidths(Array(repeating: 1 / Double(tabs.count), count: tabs.count), for: tabs)
    }

    /// Moves the keys to the pane beside the one in front.
    func focusAdjacentPane(_ delta: Int) {
        guard let tabs = splitTabs, let current = currentTab,
              let i = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        let j = i + delta
        if tabs.indices.contains(j) { select(tabs[j]) }
    }

    /// The sidebar's rows: a split shows once, as the row of whichever of its tabs comes first.
    func collapsingSplits(_ tabs: [BrowserTab]) -> [BrowserTab] {
        var seen = Set<UUID>()
        return tabs.filter { tab in
            guard let group = library.splits.group(containing: tab.id), library.splitTabs(of: tab) != nil else { return true }
            return seen.insert(group.id).inserted
        }
    }

    /// The Pinned rows the sidebar shows in a space.
    func pinnedRows(in space: Space) -> [BrowserTab] { collapsingSplits(space.pinned) }

    /// The Today rows the sidebar shows in a space.
    func todayRows(in space: Space) -> [BrowserTab] { collapsingSplits(listedToday(in: space)) }

    /// The tabs a sidebar row stands for: one tab, or a whole split as this window lists it.
    func rowTabs(_ tab: BrowserTab) -> [BrowserTab] {
        guard let tabs = library.splitTabs(of: tab)?.filter(lists), tabs.count > 1 else { return [tab] }
        return tabs
    }

    /// After `tab` moved (dragged, pinned, sent to a space): the rest of its split follows, so the
    /// split stays one row. `tabs` is the split as it was before the move.
    func keepSplitTogether(_ tabs: [BrowserTab], following tab: BrowserTab) {
        guard tabs.count > 1, let space = space(containing: tab) else { return }
        var previous = tab
        for mate in tabs where mate.id != tab.id {
            if self.space(containing: mate)?.id != space.id {
                library.move(mate, to: space)
            }
            let list = tab.isPinned ? space.pinned : space.today
            let after = list.firstIndex { $0.id == previous.id }.flatMap { i in list[(i + 1)...].first { $0.id != mate.id } }
            library.move(mate, before: after, pinned: tab.isPinned, fallback: space)
            if !mate.isPinned { mate.windowKey = tab.windowKey ?? windowKey }
            previous = mate
        }
    }
}
