import SwiftUI
import UniformTypeIdentifiers
import BrowserCore
import Suggest

/// Safari-style tab overview, for when there's no room for the sidebar (the outer display).
/// Unfolded, the sidebar is the tab list and the same vertical-bar slot toggles it instead.
///
/// - Opening it shrinks the current page into its card; picking a card grows that page back to
///   full screen. Both are one `matchedGeometryEffect` between a full-screen "hero" picture and
///   the card's thumbnail, driven by a single spring.
/// - Pinned tabs sit in a row at the top, Today's tabs in a grid below: two columns folded,
///   as many as fit unfolded.
/// - Swipe a card sideways or tap its ✕ to close it. Long-press for the tab menu, or drag it to
///   reorder.
struct TabGridOverlay: View {
    @Environment(BrowserState.self) private var browser
    @Namespace private var ns

    /// Overlay is in the hierarchy.
    @State private var shown = false
    /// The hero picture covers the screen (opening start, closing end).
    @State private var expanded = false
    @State private var heroID: UUID?
    @State private var size: CGSize = .init(width: 390, height: 844)

    var body: some View {
        ZStack {
            if shown {
                grid
                    .background(Color(.systemGroupedBackground).opacity(expanded ? 0 : 1))
                if expanded, let id = heroID, let tab = tab(id) {
                    TabThumbnail(tab: tab, image: browser.thumbnails[id], cornerRadius: 0)
                        .ignoresSafeArea()
                        .matchedGeometryEffect(id: id, in: ns)
                        .allowsHitTesting(false)
                        .transition(.identity)
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        // Unfolding with the grid up: the sidebar takes over, so just get out of the way.
        .onChange(of: browser.isUnfolded) { _, unfolded in if unfolded && shown { finish() } }
        .onChange(of: browser.isTabSwitcherPresented) { _, wanted in
            if wanted { open() } else if shown { close(into: browser.currentTab) }
        }
    }

    // MARK: Open and close

    private func open() {
        // Unfolded, the request goes to the sidebar instead (UnfoldedLayout handles it).
        guard !shown, !browser.isUnfolded else { return }
        if let tab = browser.currentTab { browser.captureThumbnail(of: tab) }
        heroID = browser.currentTab?.id
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { shown = true; expanded = heroID != nil }
        // Next frame: the hero flies into its card.
        Task { @MainActor in
            withAnimation(Motion.spring) { expanded = false }
        }
    }

    /// Grows `tab`'s card back to full screen and leaves the grid. With no tab, just fades out.
    private func close(into tab: BrowserTab?) {
        if let tab {
            browser.select(tab)
            heroID = tab.id
            withAnimation(Motion.spring) { expanded = true } completion: { finish() }
        } else {
            withAnimation(Motion.snappy) { shown = false } completion: { finish() }
        }
    }

    private func finish() {
        shown = false
        expanded = false
        if browser.isTabSwitcherPresented { browser.isTabSwitcherPresented = false }
    }

    private func tab(_ id: UUID) -> BrowserTab? { browser.currentSpace.allTabs.first { $0.id == id } }

    // MARK: Grid

    private var aspect: CGFloat { max(0.4, min(2, size.width / max(size.height, 1))) }

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
                        ForEach(space.today) { tab in card(tab).id(tab.id) }
                    }
                    .padding(.horizontal, 16)
                    if space.today.isEmpty && space.pinned.isEmpty {
                        ContentUnavailableView("No tabs", systemImage: "square.on.square",
                                               description: Text("Tap plus to open one."))
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 90)
            }
            .onAppear { if let id = heroID { proxy.scrollTo(id, anchor: .center) } }
        }
        .overlay(alignment: .bottom) { bottomBar }
        .opacity(expanded ? 0.001 : 1)   // stays laid out so the hero has a card to fly to
        .animation(Motion.snappy, value: space.today.map(\.id))
        .onKeyPress(.escape) { close(into: browser.currentTab); return .handled }
    }

    private func card(_ tab: BrowserTab) -> some View {
        TabGridCard(tab: tab, selected: tab.id == browser.currentSpace.selectedTabID, aspect: aspect,
                    hidden: expanded && heroID == tab.id, ns: ns,
                    onOpen: { close(into: tab) },
                    onClose: { withAnimation(Motion.snappy) { browser.close(tab) } })
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
                // Leave without the zoom: the new-tab sheet is the next thing to animate.
                shown = false
                expanded = false
                browser.isTabSwitcherPresented = false
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
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// One card: the page picture with a close button, and the title underneath.
private struct TabGridCard: View {
    @Environment(BrowserState.self) private var browser
    let tab: BrowserTab
    let selected: Bool
    let aspect: CGFloat
    /// The hero is standing in for this card's picture.
    let hidden: Bool
    let ns: Namespace.ID
    var onOpen: () -> Void
    var onClose: () -> Void
    @State private var dragX: CGFloat = 0

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onOpen) {
                ZStack {
                    Color.clear
                    if !hidden {
                        TabThumbnail(tab: tab, image: browser.thumbnails[tab.id], cornerRadius: 14)
                            .matchedGeometryEffect(id: tab.id, in: ns)
                            .transition(.identity)
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                      lineWidth: selected ? 3 : 0.5)
                        .opacity(hidden ? 0 : 1)
                }
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .topTrailing) {
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.bold))
                    .frame(width: 26, height: 26)
                    .background(.ultraThinMaterial, in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
                    .opacity(hidden ? 0 : 1)
            }
            HStack(spacing: 6) {
                if let url = tab.url { FaviconView(url: url, size: 14) }
                Text(tab.displayTitle).font(.caption).lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .offset(x: dragX)
        .opacity(1 - min(0.6, abs(dragX) / 300))
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { v in
                    if abs(v.translation.width) > abs(v.translation.height) * 1.5 { dragX = v.translation.width }
                }
                .onEnded { v in
                    let proj = v.predictedEndTranslation.width
                    if abs(dragX) > 0, abs(proj) > 140 {
                        withAnimation(Motion.snappy) { dragX = proj > 0 ? 500 : -500 } completion: { onClose() }
                    } else {
                        withAnimation(Motion.bouncy) { dragX = 0 }
                    }
                }
        )
        .contextMenu { TabMenu(tab: tab) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityValue(selected ? "Current tab" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .accessibilityAction(named: "Close Tab") { onClose() }
    }
}

/// A tab's page picture, or its icon on a plain card when there isn't one yet.
struct TabThumbnail: View {
    let tab: BrowserTab
    let image: UIImage?
    var cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ZStack {
                    Color(.secondarySystemGroupedBackground)
                    if let url = tab.url { FaviconView(url: url, size: 40) }
                    else { Image(systemName: "plus.square.on.square").font(.largeTitle).foregroundStyle(.tertiary) }
                }
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
    }
}
