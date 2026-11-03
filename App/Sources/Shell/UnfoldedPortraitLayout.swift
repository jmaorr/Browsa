import SwiftUI
import BrowserCore

/// Inner display, portrait: the page gets the whole width and scrolls under the status bar.
///
/// - Bottom: `NoGutterBar`, with everything in reach. The top is just the status bar.
/// - The sidebar slides in over the page and never resizes it. Tap outside it to put it away.
struct UnfoldedPortraitLayout: View {
    @Environment(BrowserState.self) private var browser
    @State private var isSidebarShown = false
    @State private var topInset: CGFloat = 0
    @State private var bottomInset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack {
                page
                    .toolbar(.hidden, for: .navigationBar)
                    .pageColoredSurroundings(browser.currentTab)
            }
            if isSidebarShown {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { setSidebar(false) }
                    .transition(.opacity)
                sidebar.transition(.move(edge: .leading))
            }
        }
        // Measured outside the stack, whose bar counts as safe area until it has finished hiding.
        .onGeometryChange(for: CGFloat.self) { BarMetrics.topCornerInset($0) } action: { topInset = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
        // "Show All Tabs" (⇧⌘\\) means the sidebar here, not the grid.
        .onChange(of: browser.isTabSwitcherPresented) { _, wanted in
            guard wanted else { return }
            browser.isTabSwitcherPresented = false
            setSidebar(!isSidebarShown)
        }
        // Picking a tab puts the sidebar away. Changing space changes the tab too, but stays open.
        .onChange(of: browser.currentTab?.id) {
            let changedSpace = browser.lastSpaceSwitch.map { Date().timeIntervalSince($0.at) < 0.3 } ?? false
            if !changedSpace { setSidebar(false) }
        }
        .onChange(of: browser.isNewTabSheetPresented) { _, presented in if presented { setSidebar(false) } }
        .background {
            // Hardware keyboard: Cmd-S toggles the sidebar, like Arc.
            Button("") { setSidebar(!isSidebarShown) }.keyboardShortcut("s", modifiers: .command).hidden()
        }
    }

    private var page: some View {
        ZStack {
            WebContentView(topObscuredInset: topInset, bottomObscuredInset: BarMetrics.underCapsuleInset)
                .ignoresSafeArea(.all, edges: .vertical)
            Color.clear
                .allowsHitTesting(false)
                .overlay(alignment: .bottom) { NoGutterBar(bottomInset: bottomInset) { setSidebar(!isSidebarShown) } }
        }
    }

    private var sidebar: some View {
        SidebarView(showsAddress: false)
            .padding(.vertical, 12)
            // Clears the status bar or an iPad window's controls.
            .padding(.top, topInset)
            .frame(width: 320)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .vertical)
            .background {
                let shape = UnevenRoundedRectangle(bottomTrailingRadius: 24, topTrailingRadius: 24, style: .continuous)
                ZStack {
                    shape.fill(.regularMaterial)
                    shape.fill(SpacePalette.color(for: browser.currentSpace).opacity(SpacePalette.surfaceOpacity))
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

/// The bottom bar for a big screen with no vertical bar beside the page: the sidebar button and
/// plus at the edges, in reach of your hands, with the arrows and address between them.
/// The rest of the page's controls are in the address sheet, as on a phone.
struct NoGutterBar: View {
    @Environment(BrowserState.self) private var browser
    var bottomInset: CGFloat
    var onToggleSidebar: () -> Void

    private var compact: Bool { browser.currentTab?.isChromeCompact ?? false }

    var body: some View {
        HStack(spacing: 8) {
            if !compact {
                SidebarButton(action: onToggleSidebar)
                    .glassCircleButton()
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            if !compact {
                HStack(spacing: 0) {
                    HistoryButton(forward: false).frame(width: 42, height: BarMetrics.capsuleHeight).contentShape(.rect)
                    HistoryButton(forward: true).frame(width: 42, height: BarMetrics.capsuleHeight).contentShape(.rect)
                }
                .labelStyle(.iconOnly)
                .fontWeight(.medium)
                .glassEffect(.regular.interactive(), in: .capsule)
                .transition(.opacity)
            }
            BottomBar(sideMargin: 0, compactDrop: BarMetrics.compactDrop(bottomInset: bottomInset))
                .frame(maxWidth: compact ? nil : BarMetrics.noGutterAddressWidth)
            Spacer(minLength: 0)
            if !compact {
                if browser.downloads.isIndicatorVisible {
                    DownloadProgressButton().glassCircleButton().transition(.opacity)
                }
                NewTabButton().glassCircleButton().transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .animation(Motion.collapse, value: compact)
        .hiddenWhileKeyboardIsUp()
    }
}
