import SwiftUI
import BrowserCore
import Suggest

/// Outer display: one-handed phone layout. System vertical bar off; our own Arc-style bottom bar
/// with the address pill and a plus button on the right, in thumb reach.
struct FoldedLayout: View {
    @Environment(BrowserState.self) private var browser
    @Environment(TabRailController.self) private var rail

    var body: some View {
        // The bar floats over the page (it doesn't resize it), so collapsing it never reflows the page.
        WebContentView(bottomObscuredInset: 64)
            .ignoresSafeArea(.container, edges: .bottom)
            .overlay(alignment: .bottom) { BottomBar() }
            // Leading-edge swipe scrubs through tabs (WebKit's swipe-back is turned off).
            .overlay(alignment: .leading) { TabRailEdge().padding(.bottom, 96) }
            .onAppear { rail.sidebarShowsTabs = false }
            .duoDisableVerticalBar()
    }
}

struct BottomBar: View {
    @Environment(BrowserState.self) private var browser
    @State private var dragX: CGFloat = 0

    /// Collapsed to a small centred pill while the page scrolls down (Safari-style).
    private var compact: Bool { browser.currentTab?.isChromeCompact ?? false }
    private static let collapse = Animation.interpolatingSpring(mass: 1, stiffness: 300, damping: 26)
    private static let sideControl = AnyTransition.scale(scale: 0.4).combined(with: .opacity)

    var body: some View {
        HStack(spacing: 10) {
            if !compact, let tab = browser.currentTab {
                Button("Back", systemImage: "chevron.backward") { browser.session(for: tab).webView.goBack() }
                    .labelStyle(.iconOnly)
                    .disabled(!tab.canGoBack)
                    .frame(width: 44, height: 44)
                    .transition(Self.sideControl)
            }

            addressPill

            if !compact { plusButton.transition(Self.sideControl) }
        }
        .padding(.horizontal, compact ? 0 : 16)
        .padding(.vertical, compact ? 2 : 8)
        .frame(maxWidth: .infinity)
        .animation(Self.collapse, value: compact)
        .sensoryFeedback(.selection, trigger: browser.currentTab?.id)
    }

    private var plusButton: some View {
            Button { browser.presentNewTab(from: NewTabSource.bottomBar.rawValue) } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("New Tab")
            .newTabZoomSource(.bottomBar)
            .contextMenu {
                Button("New Private Tab", systemImage: "eye.slash") {
                    browser.newTab(url: nil, isPrivate: true)
                    browser.presentAddressEditor()
                }
                ForEach(browser.spaces) { s in
                    Button("New Tab in \(s.name)", systemImage: s.symbol) {
                        browser.selectSpace(s)
                        browser.presentNewTab()
                    }
                }
            }
    }

    /// Tap: edit address. Swipe left/right: previous/next tab. Swipe up: tab switcher.
    private var addressPill: some View {
        let tab = browser.currentTab
        return HStack(spacing: 8) {
            if let url = tab?.url {
                FaviconView(url: url, size: 18)
                Text(URLNormalizer.displayHost(url)).lineLimit(1)
                    .contentTransition(.interpolate)
            } else {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text("Search or enter address").foregroundStyle(.secondary).lineLimit(1)
            }
        }
        // Swiping to the next tab pushes the old label out and the new one in, from the swipe side.
        .id(tab?.id)
        .transition(.push(from: browser.lastTabSwipeForward == false ? .leading : .trailing))
        .clipped()
        .animation(Motion.snappy, value: tab?.url)
        .font(.callout)
        .scaleEffect(compact ? 0.84 : 1)
        .frame(maxWidth: compact ? 180 : .infinity, minHeight: compact ? 30 : 48)
        .padding(.horizontal, 14)
        .glassEffect(.regular.interactive(), in: .capsule)
        .offset(x: dragX * 0.3)
        .contentShape(.capsule)
        .newTabZoomSource(.addressPill)
        .onTapGesture {
            if compact, let tab = browser.currentTab {
                withAnimation(Self.collapse) { browser.session(for: tab).expandChrome() }
            } else {
                browser.presentAddressEditor(from: NewTabSource.addressPill.rawValue)
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
        .accessibilityHint("Double-tap to edit. Swipe up for tabs.")
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

/// Swipe-up sheet on the folded layout: spaces + tabs.
struct TabSwitcherSheet: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        let space = browser.currentSpace
        NavigationStack {
            List {
                if !space.pinned.isEmpty {
                    Section("Pinned") { ForEach(space.pinned) { row($0) } }
                }
                Section("Today") {
                    ForEach(space.today) { row($0) }
                        .onDelete { idx in idx.map { space.today[$0] }.forEach(browser.close) }
                }
            }
            .navigationTitle(space.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Space", selection: Binding(get: { browser.selectedSpaceID },
                                                       set: { id in if let s = browser.spaces.first(where: { $0.id == id }) { browser.selectSpace(s) } })) {
                        ForEach(browser.spaces) { s in Label(s.name, systemImage: s.symbol).tag(s.id) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { browser.isTabSwitcherPresented = false }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Settings", systemImage: "gearshape") {
                        browser.isTabSwitcherPresented = false
                        browser.isSettingsPresented = true
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("New Tab", systemImage: "plus") {
                        browser.isTabSwitcherPresented = false
                        browser.presentNewTab()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ tab: BrowserTab) -> some View {
        Button {
            browser.select(tab)
            browser.isTabSwitcherPresented = false
        } label: {
            TabRow(tab: tab, selected: tab.id == browser.currentSpace.selectedTabID).allowsHitTesting(false)
        }
        .contextMenu { TabMenu(tab: tab) }
    }
}
