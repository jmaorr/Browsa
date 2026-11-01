import SwiftUI
import BrowserCore
import Suggest

/// Inner display: Arc-style collapsible sidebar + full-bleed web content.
/// Sidebar toggle and the one-tap plus live in the Duo's system vertical bar (landscape), or at the
/// leading edge of the top toolbar (portrait, where the system uses horizontal bars).
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

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Toggle Sidebar", systemImage: "sidebar.leading") { toggleSidebar() }
                .sensoryFeedback(.selection, trigger: browser.currentSpace.isSidebarOpen)
        }
        .duoPinnedToVerticalBar()

        ToolbarItem(placement: .topBarLeading) {
            Button("New Tab", systemImage: "plus") { browser.presentNewTab(from: NewTabSource.verticalBar.rawValue) }
                .newTabZoomSource(.verticalBar)
        }
        .duoPinnedToVerticalBar()

        ToolbarItemGroup(placement: .topBarTrailing) {
            if let tab = browser.currentTab {
                Button("Back", systemImage: "chevron.backward") { browser.session(for: tab).webView.goBack() }
                    .disabled(!tab.canGoBack)
                Button("Forward", systemImage: "chevron.forward") { browser.session(for: tab).webView.goForward() }
                    .disabled(!tab.canGoForward)
                if let url = tab.url {
                    FavoriteToggle(url: url, title: tab.displayTitle)
                    ShareLink(item: url)
                }
            }
        }
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
