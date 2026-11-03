import SwiftUI
import BrowserCore
import Suggest

/// Outer display: one-handed phone layout.
///
/// - The Duo's system vertical bar (the gutter beside the outer screen) carries the controls in two
///   groups, like Safari: back, forward (hold for history) and the page menu at the top, and
///   tabs plus new tab at the bottom, in thumb reach.
/// - The bottom bar is just the address pill, full width. Copy Link lives in the address editor
///   (and holding the pill), not in the toolbar.
///
/// A phone without the vertical bar has `PhoneLayout` instead.
struct FoldedLayout: View {
    @Environment(BrowserState.self) private var browser
    @Environment(TabRailController.self) private var rail
    @Environment(\.duoToolbarVerticalEdge) private var verticalBarEdge

    var body: some View {
        if verticalBarEdge == nil { PhoneLayout() } else { outerDisplay }
    }

    private var outerDisplay: some View {
        NavigationStack {
            // The bar floats over the page (it doesn't resize it), so collapsing it never reflows the page.
            WebContentView(bottomObscuredInset: BarMetrics.underCapsuleInset)
                // Edge to edge like Safari: the page runs under the status area and the bar.
                .ignoresSafeArea(.all, edges: .vertical)
                .overlay(alignment: .bottom) { BottomBar().hiddenWhileKeyboardIsUp() }
                // Part of the page, so the system's bars stay above it and keep working.
                .overlay(alignment: verticalBarEdge == .leading ? .leading : .trailing) {
                    TabRailEdge().padding(.bottom, 96)
                }
                .overlay { TabGridOverlay() }
                .toolbar { gutter }
                .pageColoredSurroundings(browser.currentTab, galleryIsUp: browser.tabGridCoversPage)
                .toolbarTitleDisplayMode(.inline)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .duoVerticalBarPrefersOurItems()
        }
        .onAppear { rail.sidebarShowsTabs = false }
        .onChange(of: verticalBarEdge, initial: true) { _, barEdge in
            rail.edge = barEdge ?? .trailing
            rail.isBesideVerticalBar = true
        }
    }

    @ToolbarContentBuilder private var gutter: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { HistoryButton(forward: false) }.duoPinnedToVerticalBar()
        ToolbarItem(placement: .topBarTrailing) { HistoryButton(forward: true) }.duoPinnedToVerticalBar()
        ToolbarItem(placement: .topBarTrailing) { PageMenu() }.duoPinnedToVerticalBar()
        if browser.downloads.isIndicatorVisible {
            ToolbarItem(placement: .topBarTrailing) { DownloadProgressButton() }.duoPinnedToVerticalBar()
        }
        // Bottom-bar items land at the far end of the vertical bar, beside your thumb.
        ToolbarItem(placement: .bottomBar) { NewTabButton() }.duoPinnedToVerticalBar()
        ToolbarItem(placement: .bottomBar) { TabsButton() }.duoPinnedToVerticalBar()
    }
}

/// A new-tab button. Hold for a private tab or a tab in another space. The same menu in every layout.
struct NewTabButton: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        Button("New Tab", systemImage: "plus") { browser.presentNewTab() }
            .contextMenu { NewTabMenu() }
    }
}

/// What holding a plus button offers.
struct NewTabMenu: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        Button("New Private Tab", systemImage: "eye.slash") {
            browser.newTab(url: nil, isPrivate: true)
            browser.presentAddressEditor()
        }
        ForEach(browser.regularSpaces) { s in
            Button("New Tab in \(s.name)", systemImage: s.symbol) {
                browser.selectSpace(s)
                browser.presentNewTab()
            }
        }
        if browser.privateSpace != nil {
            Divider()
            Button("Close Private Tabs", systemImage: "xmark", role: .destructive) {
                withAnimation(Motion.spring) { browser.closePrivateSpace() }
            }
        }
    }
}

struct BottomBar: View {
    @Environment(BrowserState.self) private var browser
    /// Space either side of the capsule at full size.
    var sideMargin: CGFloat = 24
    @State private var dragX: CGFloat = 0

    /// Collapsed to a small centred pill while the page scrolls down (Safari-style).
    private var compact: Bool { browser.currentTab?.isChromeCompact ?? false }

    @State private var copies = 0

    var body: some View {
        addressPill
        // No padding below: like Safari the bar rests right on the safe area, and the small pill
        // drops into it, just above the home indicator.
        .padding(.horizontal, compact ? 0 : sideMargin)
        .offset(y: compact ? BarMetrics.compactCapsuleDrop : 0)
        .frame(maxWidth: .infinity)
        .animation(Motion.collapse, value: compact)
        .sensoryFeedback(.selection, trigger: browser.currentTab?.id)
        .sensoryFeedback(.success, trigger: copies)
    }

    /// Tap: edit address. Swipe left/right: previous/next tab. Swipe up: tab switcher.
    private var addressPill: some View {
        let tab = browser.currentTab
        // The reload button's own frame gives it room, and the address needs every point on a phone.
        return HStack(spacing: 2) {
            HStack(spacing: 8) {
                if tab?.isPrivate == true {
                    Image(systemName: "eye.slash").foregroundStyle(.secondary).accessibilityLabel("Private")
                }
                if let url = tab?.url {
                    FaviconView(url: url, size: 18)
                    Text(URLNormalizer.displayHost(url)).lineLimit(1)
                        .contentTransition(.interpolate)
                } else {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search or enter address").foregroundStyle(.secondary).lineLimit(1)
                }
                if !compact { Spacer(minLength: 0) }
            }
            // Swiping to the next tab pushes the old label out and the new one in, from the swipe side.
            .id(tab?.id)
            .transition(Motion.tabPush(forward: browser.lastTabSwipeForward ?? true))
            .clipped()
            .animation(Motion.snappy, value: tab?.url)
            if !compact, let tab, tab.url != nil { ReloadButton(tab: tab) }
        }
        .font(.callout)
        .scaleEffect(compact ? 0.84 : 1)
        .frame(maxWidth: compact ? 165 : .infinity, minHeight: compact ? BarMetrics.compactCapsuleHeight : BarMetrics.capsuleHeight)
        .padding(.horizontal, 14)
        .overlay(alignment: .bottom) { if let tab { LoadingStrip(tab: tab) } }
        .clipShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .offset(x: dragX * 0.3)
        .contentShape(.capsule)
        // Press and hold the pill to copy the address straight away.
        .onLongPressGesture(minimumDuration: 0.45) {
            guard let url = browser.currentTab?.url else { return }
            browser.copyToPasteboard(url)
            browser.showToast("Link copied")
            copies += 1
        }
        .onTapGesture {
            if compact, let tab = browser.currentTab {
                withAnimation(Motion.collapse) { browser.session(for: tab).expandChrome() }
            } else {
                browser.presentAddressEditor()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in if abs(v.translation.width) > abs(v.translation.height) { dragX = v.translation.width } }
                .onEnded { v in
                    withAnimation(.snappy) { dragX = 0 }
                    let t = v.translation
                    if t.height < -40, abs(t.height) > abs(t.width) {
                        browser.isTabSwitcherPresented = true
                    } else if abs(t.width) > 60 {
                        switchTab(by: t.width < 0 ? 1 : -1)
                    }
                }
        , including: compact ? .subviews : .all)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(tab?.displayTitle ?? "Address")
        .accessibilityHint("Double-tap to edit the address.")
        // VoiceOver can't do the pill's swipes, so offer them as actions (swipe up/down to pick).
        .accessibilityAction(named: "Next Tab") { switchTab(by: 1) }
        .accessibilityAction(named: "Previous Tab") { switchTab(by: -1) }
        .accessibilityAction(named: "Show All Tabs") { browser.isTabSwitcherPresented = true }
        .accessibilityAction(named: "New Tab") { browser.presentNewTab() }
        .accessibilityAction(named: "Copy Link") {
            if let url = browser.currentTab?.url { browser.copyToPasteboard(url); browser.showToast("Link copied") }
        }
    }

    private func switchTab(by delta: Int) {
        let tabs = browser.currentSpace.allTabs
        guard let current = browser.currentTab, let i = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        let j = i + delta
        guard tabs.indices.contains(j) else {
            // End of the list: a little rubber-band nudge instead of nothing.
            withAnimation(Motion.bouncy) { dragX = delta > 0 ? -18 : 18 }
            withAnimation(Motion.bouncy.delay(0.12)) { dragX = 0 }
            return
        }
        browser.lastTabSwipeForward = delta > 0
        withAnimation(Motion.snappy) { browser.select(tabs[j]) }
        Task { try? await Task.sleep(for: .milliseconds(400)); browser.lastTabSwipeForward = nil }
    }
}
