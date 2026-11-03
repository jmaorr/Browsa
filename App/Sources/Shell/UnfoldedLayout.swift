import SwiftUI
import BrowserCore
import Suggest

/// Inner display. With the system's vertical bar beside the page there's room for a docked
/// sidebar; in portrait the system has no vertical bar, and the page gets the whole width.
/// An iPad has no vertical bar at all, so it goes by the shape of its window.
struct UnfoldedLayout: View {
    @Environment(\.duoToolbarVerticalEdge) private var verticalBarEdge
    @State private var isLandscape = false

    private var isWide: Bool {
        verticalBarEdge != nil || (UIDevice.current.userInterfaceIdiom == .pad && isLandscape)
    }

    var body: some View {
        Group {
            if isWide { UnfoldedWideLayout() } else { UnfoldedPortraitLayout() }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { isLandscape = $0 }
        // Rotating swaps layouts outright, for the same reason PostureReader does.
        .transaction(value: isWide) { t in
            t.animation = nil
            t.disablesAnimations = true
        }
    }
}

/// Inner display, wide: Arc-style collapsible sidebar + full-bleed web content.
/// The Duo's system vertical bar carries the same two groups as on the outer display (back,
/// forward and page menu up top; new tab and the sidebar button, in the tabs slot, at the bottom).
/// An iPad has no vertical bar, so they go in `NoGutterBar` at the bottom of the page.
struct UnfoldedWideLayout: View {
    @Environment(BrowserState.self) private var browser
    @Environment(TabRailController.self) private var rail
    @Environment(\.duoToolbarVerticalEdge) private var verticalBarEdge

    /// Put the sidebar on the edge opposite the system vertical bar so they never stack.
    private var sidebarEdge: HorizontalEdge { verticalBarEdge == .leading ? .trailing : .leading }
    /// The status bar alone, for the page when the docked sidebar sits under the window's controls.
    @State private var statusInset: CGFloat = 0
    @State private var topInset: CGFloat = 0
    @State private var bottomInset: CGFloat = 0

    var body: some View {
        let space = browser.currentSpace
        NavigationStack {
            SidebarContainer(isDocked: space.isSidebarOpen, edge: sidebarEdge,
                             tint: SpacePalette.color(for: space)) {
                // Clears the status bar or an iPad window's controls.
                SidebarView(showsAddress: verticalBarEdge != nil).padding(.top, verticalBarEdge == nil ? topInset : 0)
            } content: {
                if verticalBarEdge == nil {
                    WebContentView(topObscuredInset: space.isSidebarOpen ? statusInset : topInset,
                                   bottomObscuredInset: BarMetrics.underCapsuleInset)
                } else {
                    WebContentView(bottomObscuredInset: space.isSidebarOpen ? BarMetrics.dockedPageInset : BarMetrics.underCapsuleInset)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { statusInset = $0 }
            .onGeometryChange(for: CGFloat.self) { BarMetrics.topCornerInset($0) } action: { topInset = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
            // The keyboard goes over the page without resizing it. WebKit scrolls the field into view.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .overlay(alignment: .bottom) {
                if verticalBarEdge == nil {
                    // Across the page, beside the sidebar when it's docked.
                    NoGutterBar(bottomInset: bottomInset) { toggleSidebar() }
                        .padding(.leading, space.isSidebarOpen ? SidebarContainer<EmptyView, EmptyView>.defaultWidth : 0)
                } else if !space.isSidebarOpen {
                    // The sidebar holds the address; with it hidden, the same capsule as the outer display.
                    BottomBar().frame(maxWidth: 480).hiddenWhileKeyboardIsUp().transition(.opacity)
                }
            }
            .toolbar { if verticalBarEdge != nil { verticalBar } }
            .toolbar(verticalBarEdge == nil ? .hidden : .automatic, for: .navigationBar)
            // Docked, the space's tint surrounds the page instead.
            .pageColoredSurroundings(browser.currentTab, isEnabled: !space.isSidebarOpen)
            .toolbarTitleDisplayMode(.inline)
            .duoVerticalBarPrefersOurItems()
            // The docked sidebar already lists the tabs, so the strip doesn't peek then.
            .onChange(of: space.isSidebarOpen, initial: true) { _, showing in
                rail.sidebarShowsTabs = showing
            }
            // The page's edge beside the vertical bar starts the strip. An iPad has the sidebar one tap away.
            .overlay(alignment: verticalBarEdge == .leading ? .leading : .trailing) {
                if !space.isSidebarOpen, verticalBarEdge != nil { TabRailEdge() }
            }
            .onChange(of: verticalBarEdge, initial: true) { _, barEdge in
                rail.edge = barEdge ?? .leading
                rail.isBesideVerticalBar = barEdge != nil
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
    private var sidebarButton: some View {
        Button("Toggle Sidebar", systemImage: "sidebar.leading") { toggleSidebar() }
            .sensoryFeedback(.selection, trigger: browser.currentSpace.isSidebarOpen)
    }

    @ToolbarContentBuilder private var verticalBar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { HistoryButton(forward: false) }.duoPinnedToVerticalBar()
        ToolbarItem(placement: .topBarTrailing) { HistoryButton(forward: true) }.duoPinnedToVerticalBar()
        ToolbarItem(placement: .topBarTrailing) { PageMenu() }.duoPinnedToVerticalBar()
        if browser.downloads.isIndicatorVisible {
            ToolbarItem(placement: .topBarTrailing) { DownloadProgressButton() }.duoPinnedToVerticalBar()
        }
        // Bottom-bar items land at the far end of the vertical bar.
        ToolbarItem(placement: .bottomBar) { NewTabButton() }
        .duoPinnedToVerticalBar()
        ToolbarItem(placement: .bottomBar) { sidebarButton }.duoPinnedToVerticalBar()
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
