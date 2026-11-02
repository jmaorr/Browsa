import SwiftUI
import BrowserCore

/// Inner display, portrait: the page gets the whole width and scrolls under a translucent top bar.
///
/// - Top bar: back and forward on the leading side, the page menu on the trailing side.
/// - Bottom: sidebar button, address capsule, new tab.
/// - The sidebar slides in over the page and never resizes it. Tap outside it to put it away.
struct UnfoldedPortraitLayout: View {
    @Environment(BrowserState.self) private var browser
    @Environment(TabRailController.self) private var rail
    @State private var isSidebarShown = false
    @State private var topInset: CGFloat = 0

    private var compact: Bool { browser.currentTab?.isChromeCompact ?? false }

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack {
                page
                    .toolbar { topBar }
                    .pageColoredSurroundings(browser.currentTab)
                    .toolbarTitleDisplayMode(.inline)
                    .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            }
            if isSidebarShown {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { setSidebar(false) }
                    .transition(.opacity)
                sidebar.transition(.move(edge: .leading))
            }
        }
        .onAppear { rail.sidebarShowsTabs = false }
        // "Show All Tabs" (⇧⌘\\) means the sidebar here, not the grid.
        .onChange(of: browser.isTabSwitcherPresented) { _, wanted in
            guard wanted else { return }
            browser.isTabSwitcherPresented = false
            setSidebar(!isSidebarShown)
        }
        .onChange(of: browser.currentTab?.id) { setSidebar(false) }
        .onChange(of: browser.isNewTabSheetPresented) { _, presented in if presented { setSidebar(false) } }
        .background {
            // Hardware keyboard: Cmd-S toggles the sidebar, like Arc.
            Button("") { setSidebar(!isSidebarShown) }.keyboardShortcut("s", modifiers: .command).hidden()
        }
    }

    private var page: some View {
        ZStack {
            WebContentView(topObscuredInset: topInset, bottomObscuredInset: 90)
                .ignoresSafeArea(.all, edges: .vertical)
            // The bar's height is the top safe area, which the toolbar sets.
            VStack(spacing: 0) {
                Rectangle().fill(.ultraThinMaterial).frame(height: topInset)
                    .pageMatchedAppearance(browser.currentTab)
                Spacer(minLength: 0)
            }
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
            Color.clear
                .allowsHitTesting(false)
                .overlay(alignment: .bottom) { bottomBar }
                .overlay(alignment: .leading) { TabRailEdge().padding(.bottom, 96) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { topInset = $0 }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if !compact {
                Button("Show Sidebar", systemImage: "sidebar.leading") { setSidebar(true) }
                    .glassCircleButton()
                    .transition(.opacity)
            }
            BottomBar(sideMargin: 0)
            if !compact {
                NewTabButton()
                    .glassCircleButton()
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .animation(Motion.collapse, value: compact)
        .hiddenWhileKeyboardIsUp()
    }

    @ToolbarContentBuilder private var topBar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { HistoryButton(forward: false) }
        ToolbarItem(placement: .topBarLeading) { HistoryButton(forward: true) }
        if browser.downloads.isIndicatorVisible {
            ToolbarItem(placement: .topBarTrailing) { DownloadProgressButton() }
        }
        ToolbarItem(placement: .topBarTrailing) { PageMenu() }
    }

    private var sidebar: some View {
        SidebarView()
            .padding(.vertical, 12)
            .frame(width: 320)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .vertical)
            .background {
                let shape = UnevenRoundedRectangle(bottomTrailingRadius: 24, topTrailingRadius: 24, style: .continuous)
                ZStack {
                    shape.fill(.regularMaterial)
                    shape.fill(SpacePalette.color(browser.currentSpace.colorIndex).opacity(0.14))
                }
                .shadow(color: .black.opacity(0.22), radius: 24, x: 8)
                .ignoresSafeArea()
            }
    }

    private func setSidebar(_ shown: Bool) {
        guard shown != isSidebarShown else { return }
        withAnimation(Motion.spring) { isSidebarShown = shown }
    }
}
