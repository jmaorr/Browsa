import SwiftUI
import BrowserCore
import Suggest

/// Inner display: Arc-style collapsible sidebar + full-bleed web content.
/// The Duo's system vertical bar carries the same two groups as on the outer display (sidebar,
/// back, forward and page menu up top; new tab and tabs at the bottom). Where the system uses a
/// horizontal bar instead, the same items sit at the trailing end of the top toolbar.
struct UnfoldedLayout: View {
    @Environment(BrowserState.self) private var browser
    @Environment(TabRailController.self) private var rail
    @Environment(\.duoToolbarVerticalEdge) private var verticalBarEdge

    /// Put the sidebar on the edge opposite the system vertical bar so they never stack.
    private var sidebarEdge: HorizontalEdge { verticalBarEdge == .leading ? .trailing : .leading }

    @State private var isPeeking = false

    var body: some View {
        let space = browser.currentSpace
        NavigationStack {
            SidebarContainer(mode: sidebarMode, edge: sidebarEdge,
                             tint: SpacePalette.color(space.colorIndex)) {
                SidebarView()
            } content: {
                WebContentView()
            }
            .toolbar { toolbar }
            .toolbarTitleDisplayMode(.inline)
            .navigationTitle(browser.currentTab?.displayTitle ?? "")
            .duoVerticalBarPrefersOurItems()
            // The docked or peeking sidebar already lists the tabs, so the strip doesn't peek then.
            .onChange(of: space.isSidebarOpen || isPeeking, initial: true) { _, showing in
                rail.sidebarShowsTabs = showing
            }
            // Picking a tab from a peeking sidebar puts it away, like Arc.
            .onChange(of: browser.currentTab?.id) { if isPeeking { withAnimation(.smooth) { isPeeking = false } } }
        }
        .background {
            // Hardware keyboard: Cmd-S toggles the sidebar, like Arc.
            Button("") { toggleSidebar() }.keyboardShortcut("s", modifiers: .command).hidden()
        }
    }

    private var sidebarMode: Binding<SidebarContainer<SidebarView, WebContentView>.Mode> {
        Binding {
            let space = browser.currentSpace
            return space.isSidebarOpen ? .docked : (isPeeking ? .peek : .hidden)
        } set: { mode in
            let space = browser.currentSpace
            isPeeking = mode == .peek
            if space.isSidebarOpen != (mode == .docked) {
                space.isSidebarOpen = mode == .docked
                browser.scheduleSave()
            }
        }
    }

    private func toggleSidebar() {
        let space = browser.currentSpace
        withAnimation(Motion.spring) {
            if isPeeking {
                isPeeking = false
                space.isSidebarOpen = true      // pin the peeking sidebar
            } else {
                space.isSidebarOpen.toggle()
            }
        }
        browser.scheduleSave()
    }

    /// Same vertical bar as the outer display, so the controls don't move when you fold:
    /// sidebar, back, forward and the page menu at the top; new tab and tabs at the bottom.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Toggle Sidebar", systemImage: "sidebar.leading") { toggleSidebar() }
                .sensoryFeedback(.selection, trigger: browser.currentSpace.isSidebarOpen)
        }
        .duoPinnedToVerticalBar()
        ToolbarItem(placement: .topBarTrailing) { HistoryButton(forward: false) }.duoPinnedToVerticalBar()
        ToolbarItem(placement: .topBarTrailing) { HistoryButton(forward: true) }.duoPinnedToVerticalBar()
        ToolbarItem(placement: .topBarTrailing) { PageMenu() }.duoPinnedToVerticalBar()
        ToolbarSpacer(.flexible, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button("New Tab", systemImage: "plus") { browser.presentNewTab(from: NewTabSource.verticalBar.rawValue) }
                .newTabZoomSource(.verticalBar)
        }
        .duoPinnedToVerticalBar()
        ToolbarItem(placement: .topBarTrailing) { TabsButton() }.duoPinnedToVerticalBar()
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
