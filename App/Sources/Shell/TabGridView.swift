import SwiftUI
import UniformTypeIdentifiers
import BrowserCore
import Suggest

/// Safari-style tab overview, for when there's no room for the sidebar (the outer display).
/// Unfolded, the sidebar is the tab list and the same vertical-bar slot toggles it instead.
///
/// - It lives in the page's area. The Duo's vertical bar stays put and keeps working around it.
/// - Opening it shrinks the current page into its card; picking a card grows that page back. Both
///   are one picture of the page flying between two measured frames, driven by a single spring.
/// - Pinned tabs sit in a row at the top, Today's tabs in a grid below: two columns folded,
///   as many as fit unfolded.
/// - Swipe a card left or tap its ✕ to close it. Long-press for the tab menu, or drag it to
///   reorder. A scroll always wins: a swipe has to start clearly sideways, and taps are ignored
///   until the grid has come to rest.
struct TabGridOverlay: View {
    @Environment(BrowserState.self) private var browser

    /// Overlay is in the hierarchy.
    @State private var shown = false
    /// The hero picture fills the page's area (opening start, closing end).
    @State private var expanded = false
    /// The tab whose picture is flying. Its card hides its own until it lands.
    @State private var heroID: UUID?
    /// The page's area, in the overlay's coordinates.
    @State private var pageFrame: CGRect = .init(x: 0, y: 0, width: 390, height: 844)
    @State private var cardFrames = CardFrames()
    @State private var isScrolling = false
    /// A tap this soon after a scroll stops was meant for the scroll.
    @State private var scrollStoppedAt: Date = .distantPast

    private var isAtRest: Bool { !isScrolling && Date().timeIntervalSince(scrollStoppedAt) > 0.2 }

    var body: some View {
        ZStack {
            if shown {
                grid
                    .background(Color(.systemGroupedBackground).opacity(expanded ? 0 : 1), ignoresSafeAreaEdges: .vertical)
                if let id = heroID, let tab = tab(id) {
                    let frame = expanded ? pageFrame : (cardFrames.byTab[id] ?? pageFrame)
                    TabThumbnail(tab: tab, image: browser.thumbnails[id], cornerRadius: expanded ? 0 : 14)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                }
            }
        }
        .background {
            Color.clear
                .ignoresSafeArea(.container, edges: .vertical)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(galleryCoordinates)) } action: { pageFrame = $0 }
        }
        .coordinateSpace(.named(galleryCoordinates))
        // Unfolding with the grid up: the sidebar takes over, so just get out of the way.
        .onDisappear { if shown { finish() } }
        // Any plus button: the new-tab sheet is the next thing to animate, so leave without the zoom.
        .onChange(of: browser.isNewTabSheetPresented) { _, presented in if presented && shown { finish() } }
        .onChange(of: browser.isTabSwitcherPresented) { _, wanted in
            if wanted { open() } else if shown { close(into: browser.currentTab) }
        }
    }

    // MARK: Open and close

    private func open() {
        guard !shown else { return }
        if let tab = browser.currentTab { browser.captureThumbnail(of: tab) }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            heroID = browser.currentTab?.id
            shown = true
            expanded = heroID != nil
        }
        fly {
            expanded = false
            browser.tabGridCoversPage = true
        } landed: {
            if !expanded { heroID = nil }
        }
    }

    /// Grows `tab`'s card back to fill the page's area and leaves the grid. With no tab, just fades out.
    private func close(into tab: BrowserTab?) {
        if let tab {
            browser.select(tab)
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { heroID = tab.id }
            fly {
                expanded = true
                browser.tabGridCoversPage = false
            } landed: {
                if expanded { finish() }
            }
        } else {
            withAnimation(Motion.snappy) {
                shown = false
                browser.tabGridCoversPage = false
            } completion: { finish() }
        }
    }

    /// Gives the hero one frame in its starting place (and the grid its first layout), then flies.
    private func fly(_ change: @escaping () -> Void, landed: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            withAnimation(Motion.spring, change, completion: landed)
        }
    }

    private func finish() {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            shown = false
            expanded = false
            heroID = nil
            browser.tabGridCoversPage = false
        }
        if browser.isTabSwitcherPresented { browser.isTabSwitcherPresented = false }
    }

    private func tab(_ id: UUID) -> BrowserTab? { browser.currentSpace.allTabs.first { $0.id == id } }

    // MARK: Grid

    private var aspect: CGFloat { max(0.4, min(2, pageFrame.width / max(pageFrame.height, 1))) }

    private var columns: [GridItem] {
        browser.isUnfolded
            ? [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 16)]
            : [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
    }

    private var grid: some View {
        let space = browser.currentSpace
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !space.pinned.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) { ForEach(space.pinned) { pinnedChip($0) } }
                                .padding(.horizontal, 16)
                        }
                    }
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(Array(space.today.enumerated()), id: \.element.id) { i, tab in
                            card(tab)
                                .spaceCascade(index: i, distance: 360, spaceSwitch: browser.lastSpaceSwitch)
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .id(space.id)
                    .transition(.spaceListChange(forward: browser.lastSpaceSwitch?.forward ?? true))
                    if space.today.isEmpty && space.pinned.isEmpty {
                        ContentUnavailableView("No tabs", systemImage: "square.on.square",
                                               description: Text("Tap plus to open one."))
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 90)
            }
            .onScrollPhaseChange { _, phase in
                if isScrolling && !phase.isScrolling { scrollStoppedAt = .now }
                isScrolling = phase.isScrolling
            }
            .onAppear { if let id = heroID { proxy.scrollTo(id, anchor: .center) } }
        }
        .overlay(alignment: .bottom) { bottomBar }
        .opacity(expanded ? 0 : 1)   // stays laid out so the hero has a card to fly to
        .animation(Motion.snappy, value: space.today.map(\.id))
        .onKeyPress(.escape) { close(into: browser.currentTab); return .handled }
    }

    private func card(_ tab: BrowserTab) -> some View {
        TabGridCard(tab: tab, selected: tab.id == browser.currentSpace.selectedTabID, aspect: aspect,
                    hidden: heroID == tab.id, frames: cardFrames,
                    onOpen: { if isAtRest { close(into: tab) } },
                    onCloseTapped: { if isAtRest { withAnimation(Motion.snappy) { browser.close(tab) } } },
                    onSwipedAway: { withAnimation(Motion.snappy) { browser.close(tab) } })
            .draggable(tab.id.uuidString) {
                TabThumbnail(tab: tab, image: browser.thumbnails[tab.id], cornerRadius: 14)
                    .frame(width: 140, height: 140 / aspect)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let id = UUID(uuidString: raw), let moved = self.tab(id) else { return false }
                withAnimation(Motion.snappy) { browser.moveTab(moved, before: tab) }
                return true
            }
    }

    private func pinnedChip(_ tab: BrowserTab) -> some View {
        let selected = tab.id == browser.currentSpace.selectedTabID
        return Button { close(into: tab) } label: {
            HStack(spacing: 8) {
                if let url = tab.url { FaviconView(url: url, size: 18) } else { Image(systemName: "pin.fill") }
                Text(tab.displayTitle).font(.subheadline).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.background, in: .capsule)
            .overlay { if selected { Capsule().strokeBorder(.tint, lineWidth: 2) } }
        }
        .buttonStyle(.plain)
        .contextMenu { TabMenu(tab: tab) }
        .accessibilityLabel("\(tab.displayTitle), pinned")
    }

    private var bottomBar: some View {
        HStack {
            Button("New Tab", systemImage: "plus") {
                browser.presentNewTab()
            }
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            Spacer()
            Menu {
                ForEach(browser.spaces) { s in
                    Button { withAnimation(Motion.snappy) { browser.selectSpace(s) } } label: {
                        Label(s.name, systemImage: s.symbol)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(browser.currentSpace.name).fontWeight(.semibold)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .foregroundStyle(.primary)
            }
            .accessibilityLabel("Space, \(browser.currentSpace.name)")
            Spacer()
            Button("Done") { close(into: browser.currentTab) }
                .fontWeight(.semibold)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 24)
    }
}
