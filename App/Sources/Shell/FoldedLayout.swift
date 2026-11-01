import SwiftUI
import BrowserCore
import Suggest

/// Outer display: one-handed phone layout. System vertical bar off; our own Arc-style bottom bar
/// with the address pill and a plus button on the right, in thumb reach.
struct FoldedLayout: View {
    @Environment(BrowserState.self) private var browser

    var body: some View {
        WebContentView()
            .ignoresSafeArea(.container, edges: .bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) { BottomBar() }
            .duoDisableVerticalBar()
    }
}

struct BottomBar: View {
    @Environment(BrowserState.self) private var browser
    @State private var dragX: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            if let tab = browser.currentTab {
                Button("Back", systemImage: "chevron.backward") { browser.session(for: tab).webView.goBack() }
                    .labelStyle(.iconOnly)
                    .disabled(!tab.canGoBack)
                    .frame(width: 44, height: 44)
            }

            addressPill

            Button { browser.presentNewTab() } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel("New Tab")
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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .sensoryFeedback(.selection, trigger: browser.currentTab?.id)
    }

    /// Tap: edit address. Swipe left/right: previous/next tab. Swipe up: tab switcher.
    private var addressPill: some View {
        let tab = browser.currentTab
        return HStack(spacing: 8) {
            if let url = tab?.url {
                FaviconView(url: url, size: 18)
                Text(URLNormalizer.displayHost(url)).lineLimit(1)
            } else {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text("Search or enter address").foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, minHeight: 48)
        .padding(.horizontal, 14)
        .glassEffect(.regular.interactive(), in: .capsule)
        .offset(x: dragX * 0.3)
        .contentShape(.capsule)
        .onTapGesture { browser.presentAddressEditor() }
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
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(tab?.displayTitle ?? "Address")
        .accessibilityHint("Double-tap to edit. Swipe up for tabs.")
    }

    private func switchTab(by delta: Int) {
        let tabs = browser.currentSpace.allTabs
        guard let current = browser.currentTab, let i = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        let j = i + delta
        guard tabs.indices.contains(j) else { return }
        withAnimation(.smooth) { browser.select(tabs[j]) }
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

    private func row(_ tab: Tab) -> some View {
        Button {
            browser.select(tab)
            browser.isTabSwitcherPresented = false
        } label: {
            TabRow(tab: tab, selected: tab.id == browser.currentSpace.selectedTabID).allowsHitTesting(false)
        }
        .contextMenu { TabMenu(tab: tab) }
    }
}
