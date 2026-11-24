import Foundation
import Testing
@testable import BrowserCore

@Suite struct PinnedOutlineTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let f = UUID(), g = UUID()

    /// a, [f: b, [g: c]], d
    var layout: [PinnedNode] {
        [.tab(a),
         .folder(PinnedFolder(id: f, name: "Work", children: [.tab(b), .folder(PinnedFolder(id: g, name: "Docs", children: [.tab(c)]))])),
         .tab(d)]
    }

    @Test func flattensInSidebarOrder() {
        #expect(PinnedOutline.tabIDs(layout) == [a, b, c, d])
        #expect(PinnedOutline.path(of: c, in: layout) == [f, g])
        #expect(PinnedOutline.place(of: g, in: layout) == PinnedPlace(parent: f, index: 1))
    }

    @Test func reconcilesWithPinnedTabs() {
        let e = UUID()
        // b unpinned, e pinned just before d.
        let out = PinnedOutline.reconciled(layout, tabs: [a, c, e, d])
        #expect(PinnedOutline.tabIDs(out) == [a, c, e, d])
        // The empty-of-b folder stays; e lands beside d at the top level.
        #expect(PinnedOutline.place(of: e, in: out) == PinnedPlace(parent: nil, index: 2))
        // A tab pinned at the end goes at the end; one with no layout at all is a flat list.
        #expect(PinnedOutline.tabIDs(PinnedOutline.reconciled([], tabs: [a, b])) == [a, b])
        let x = UUID()
        #expect(PinnedOutline.reconciled(layout, tabs: [a, b, c, d, x]).last == .tab(x))
    }

    @Test func newTabGoesIntoTheFolderOfItsNeighbour() {
        let e = UUID()
        let out = PinnedOutline.reconciled(layout, tabs: [a, e, b, c, d])
        #expect(PinnedOutline.place(of: e, in: out) == PinnedPlace(parent: f, index: 0))
    }

    @Test func movesAndRefusesToNestAFolderInItself() {
        let moved = PinnedOutline.moving(d, to: PinnedPlace(parent: g, index: 0), in: layout)
        #expect(PinnedOutline.tabIDs(moved) == [a, b, d, c])
        #expect(PinnedOutline.moving(f, to: PinnedPlace(parent: g, index: 0), in: layout) == layout)
        let outer = PinnedOutline.moving(g, to: PinnedPlace(parent: nil, index: 0), in: layout)
        #expect(PinnedOutline.place(of: g, in: outer) == PinnedPlace(parent: nil, index: 0))
    }

    @Test func dissolvingKeepsTheTabsInPlace() {
        let out = PinnedOutline.dissolving(f, in: layout)
        #expect(PinnedOutline.tabIDs(out) == [a, b, c, d])
        #expect(PinnedOutline.place(of: g, in: out) == PinnedPlace(parent: nil, index: 2))
    }

    @Test func closedFoldersHideAllButTheSelectedTab() {
        let closed = PinnedOutline.updating(f, in: layout) { $0.isOpen = false }
        #expect(PinnedOutline.rows(closed).map(\.id) == [a, f, d])
        // The tab you're on still shows, with the folders that lead to it.
        #expect(PinnedOutline.rows(closed, selected: c).map(\.id) == [a, f, g, c, d])
        // Dragging a folder hides what's in it.
        #expect(PinnedOutline.rows(layout, hiding: f).map(\.id) == [a, d])
    }

    @Test func dropPlacesFollowDepth() {
        let rows = PinnedOutline.rows(layout) // a, f, b, g, c, d
        // Right after the folder header: inside it, at the top.
        #expect(PinnedOutline.depths(at: 2, in: rows) == 1...1)
        #expect(PinnedOutline.place(at: 2, depth: 0, rows: rows, layout: layout) == PinnedPlace(parent: f, index: 0))
        // After c, before d: in g, in f, or at the top level.
        #expect(PinnedOutline.depths(at: 5, in: rows) == 0...2)
        #expect(PinnedOutline.place(at: 5, depth: 2, rows: rows, layout: layout) == PinnedPlace(parent: g, index: 1))
        #expect(PinnedOutline.place(at: 5, depth: 1, rows: rows, layout: layout) == PinnedPlace(parent: f, index: 2))
        #expect(PinnedOutline.place(at: 5, depth: 0, rows: rows, layout: layout) == PinnedPlace(parent: nil, index: 2))
        #expect(PinnedOutline.place(at: 0, depth: 3, rows: rows, layout: layout) == PinnedPlace(parent: nil, index: 0))
        // At the very end, under d.
        #expect(PinnedOutline.place(at: 6, depth: 0, rows: rows, layout: layout) == PinnedPlace(parent: nil, index: 3))
    }

    @Test func roundTripsThroughJSON() throws {
        let back = try JSONDecoder().decode([PinnedNode].self, from: JSONEncoder().encode(layout))
        #expect(back == layout)
    }

    @Test @MainActor func spaceRecordKeepsFolders() {
        let tabs = [a, b, c, d].map { BrowserTab(id: $0, url: URL(string: "https://example.com"), isPinned: true) }
        let space = Space(name: "Work", pinned: tabs)
        #expect(space.record.pinnedLayout == nil)
        space.pinnedLayout = layout
        let back = Space(space.record)
        #expect(back.pinnedTree == layout)
    }
}
