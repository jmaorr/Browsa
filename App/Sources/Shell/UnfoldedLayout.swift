import SwiftUI
import BrowserCore
import Suggest

/// Inner display: Arc-style collapsible sidebar + full-bleed web content.
/// The Duo's system vertical bar carries the same two groups as on the outer display (back,
/// forward and page menu up top; new tab and the sidebar button, in the tabs slot, at the bottom). Where the system uses a
/// horizontal bar instead, the same items sit at the trailing end of the top toolbar.
struct UnfoldedLayout: View {
    @Environment(BrowserState.self) private var browser
    @Environment(TabRailController.self) private var rail
    @Environment(\.duoToolbarVerticalEdge) private var verticalBarEdge

    /// Put the sidebar on the edge opposite the system vertical bar so they never stack.
    private var sidebarEdge: HorizontalEdge { verticalBarEdge == .leading ? .trailing : .leading }

    /// Without the vertical bar the controls sit in a top toolbar, so the page must stop below it.
    private var fullBleedEdges: Edge.Set { verticalBarEdge == nil ? .bottom : .vertical }

    var body: some View {
        let space = browser.currentSpace
        NavigationStack {
            SidebarContainer(isDocked: space.isSidebarOpen, edge: sidebarEdge,
                             tint: SpacePalette.color(space.colorIndex), fullBleedEdges: fullBleedEdges) {
                SidebarView()
            } content: {
                WebContentView(bottomObscuredInset: space.isSidebarOpen ? 24 : 90)
            }
            // The sidebar holds the address; with it hidden, the same capsule as the outer display.
            .overlay(alignment: .bottom) {
                if !space.isSidebarOpen {
                    BottomBar().frame(maxWidth: 480).transition(.opacity)
                }
            }
            .toolbar { toolbar }
            .toolbarTitleDisplayMode(.inline)
            .duoVerticalBarPrefersOurItems()
            // The docked sidebar already lists the tabs, so the strip doesn't peek then.
            .onChange(of: space.isSidebarOpen, initial: true) { _, showing in
                rail.sidebarShowsTabs = showing
            }
            // "Show All Tabs" (⇧⌘\\) means the sidebar here, not the grid.
            .onChange(of: browser.isTabSwitcherPresented) { _, wanted in
                guard wanted else { return }
                browser.isTabSwitcherPresented = false
                toggleSidebar()
            }
        }
        .background {
            // Hardware keyboard: Cmd-S toggles the sidebar, like Arc.
            Button("") { toggleSidebar() }.keyboardShortcut("s", modifiers: .command).hidden()
        }
    }

    private func toggleSidebar() {
        let space = browser.currentSpace
        withAnimation(Motion.spring) { space.isSidebarOpen.toggle() }
        browser.scheduleSave()
    }

    /// Same vertical bar as the outer display, so the controls don't move when you fold:
    /// back, forward and the page menu at the top; new tab and tabs at the bottom. Here the
    /// tabs slot is the sidebar button, because the sidebar is the tab list. Tabs are always
    /// in the same place, whichever way the phone is.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Bottom-bar items land at the far end of the vertical bar. With no vertical bar they'd
        // make a real bottom bar, so everything stays together in the top toolbar.
        let lower: ToolbarItemPlacement = verticalBarEdge == nil ? .topBarTrailing : .bottomBar
        ToolbarItem(placement: .topBarTrailing) { HistoryButton(forward: false) }.duoPinnedToVerticalBar()
        ToolbarItem(placement: .topBarTrailing) { HistoryButton(forward: true) }.duoPinnedToVerticalBar()
        ToolbarItem(placement: .topBarTrailing) { PageMenu() }.duoPinnedToVerticalBar()
        ToolbarItem(placement: lower) {
            Button("New Tab", systemImage: "plus") { browser.presentNewTab(from: NewTabSource.verticalBar.rawValue) }
                .newTabZoomSource(.verticalBar)
        }
        .duoPinnedToVerticalBar()
        ToolbarItem(placement: lower) {
            Button("Toggle Sidebar", systemImage: "sidebar.leading") { toggleSidebar() }
                .sensoryFeedback(.selection, trigger: browser.currentSpace.isSidebarOpen)
        }
        .duoPinnedToVerticalBar()
    }
}

struct FavoriteToggle: View {
    @Environment(BrowserState.self) private var browser
    let url: URL
    let title: String

    var body: some View {
        let isFav = browser.isFavorite(url)
        Button(isFav ? "Remove Favourite" : "Add Favourite", systemImage: isFav ? "star.fill" : "star") {
            if isFav, let fav = browser.favorites.first(where: { URLNormalizer.key(for: $0.url) == URLNormalizer.key(for: url) }) {
                browser.removeFavorite(fav)
            } else {
                browser.addFavorite(url: url, title: title)
            }
        }
        .sensoryFeedback(.success, trigger: isFav)
    }
}
