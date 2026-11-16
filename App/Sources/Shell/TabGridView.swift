import SwiftUI
import WebKit
import UniformTypeIdentifiers
import BrowserCore
import Suggest

/// Safari-style tab overview, for when there's no room for the sidebar (the outer display).
/// Unfolded, the sidebar is the tab list and the same vertical-bar slot toggles it instead.
///
/// - It lives in the page's area. The Duo's vertical bar stays put and keeps working around it.
/// - Opening it shrinks the current page into its card; picking a card grows that page back, like
///   Safari. The flying picture is a UIKit view on top of the window (`ZoomFlight`), in window
///   coordinates, so safe areas and the bars can't nudge it, and the page underneath only changes
///   once it has landed.
/// - Pinned tabs sit in a row at the top, Today's tabs in a grid below: two columns folded,
///   as many as fit unfolded.
/// - The vertical bar's tabs button becomes a tick that closes it. The capsule at the bottom only
///   switches spaces.
/// - Swipe a card left or tap its ✕ to close it. Long-press for the tab menu, or drag it to
///   reorder. A scroll always wins: a swipe has to start clearly sideways, and taps are ignored
///   until the grid has come to rest.
struct TabGridOverlay: View {
    @Environment(BrowserState.self) private var browser

    /// Overlay is in the hierarchy.
    @State private var shown = false
    /// The cards are showing (they fade in as the page shrinks, out as a page grows back).
    @State private var cardsVisible = false
    /// The tab whose picture is flying. Its card hides its own until it lands.
    @State private var heroID: UUID?
    /// The tab a page is growing back into. The gallery has been closed as far as the tabs button
    /// is concerned, and this is what's left of it.
    @State private var closingInto: BrowserTab?
    /// The page's area in window coordinates, which the flying picture fills at full size.
    @State private var pageRect: CGRect = .zero
    /// The overlay's own size, for the cards' shape until the page has been measured.
    @State private var overlaySize = CGSize(width: 390, height: 844)
    @State private var flight = ZoomFlight()
    @State private var cardFrames = CardFrames()
    @State private var isScrolling = false
    /// A tap this soon after a scroll stops was meant for the scroll.
    @State private var scrollStoppedAt: Date = .distantPast

    private var isAtRest: Bool { !isScrolling && Date().timeIntervalSince(scrollStoppedAt) > 0.2 }

    var body: some View {
        ZStack {
            if shown {
                // Opaque from the start: the flying picture covers the page when the gallery
                // opens, and the page only changes under it once it has landed, so nothing of
                // the live page ever shows through mid-zoom.
                grid
                    .background(Color(.systemGroupedBackground), ignoresSafeAreaEdges: .vertical)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { overlaySize = $0 }
        // Unfolding with the grid up: the sidebar takes over, so just get out of the way.
        .onDisappear { flight.land(); if shown { finish() } }
        // Any plus button: the new-tab sheet is the next thing to animate, so leave without the zoom.
        .onChange(of: browser.isNewTabSheetPresented) { _, presented in if presented && shown { flight.land(); finish() } }
        .onChange(of: browser.isTabSwitcherPresented) { _, wanted in
            if wanted { open() } else if shown, closingInto == nil { close(into: browser.currentTab) }
        }
    }

    // MARK: Open and close

    /// The live web view of the tab on screen, if it's in a window.
    private var liveWebView: WKWebView? {
        guard let tab = browser.currentTab else { return nil }
        let wv = browser.session(for: tab).webView
        return wv.window == nil ? nil : wv
    }

    private func open() {
        // Asked for again while a page was still growing back: let that land at once, then open.
        if let tab = closingInto {
            flight.land()
            instantly {
                browser.select(tab)
                finish(resettingButton: false)
            }
        }
        guard !shown else { return }
        guard let tab = browser.currentTab, let wv = liveWebView, let window = wv.window,
              let picture = ZoomFlight.snapshot(of: wv) else {
            // Nothing to shrink (no tab yet): just fade the gallery in.
            instantly { shown = true }
            withAnimation(Motion.snappy) { cardsVisible = true; browser.tabGridCoversPage = true }
            return
        }
        browser.captureThumbnail(of: tab)
        let page = wv.convert(wv.bounds, to: nil)
        // The picture covers the page straight away, so the gallery can come up behind it.
        flight.start(picture, in: window, at: page, cornerRadius: 0)
        instantly {
            browser.tabGridHidesAddressBar = true
            pageRect = page
            heroID = tab.id
            shown = true
            cardsVisible = false
        }
        Task { @MainActor in
            // Let the grid lay out and scroll to the card first, so it's where the picture lands.
            try? await Task.sleep(for: .milliseconds(50))
            guard heroID == tab.id, let card = cardFrames.byTab[tab.id] else {
                flight.land()
                instantly { heroID = nil }
                withAnimation(Motion.snappy) { cardsVisible = true; browser.tabGridCoversPage = true }
                return
            }
            flight.fly(to: card, cornerRadius: TabGridCard.cornerRadius) {
                withAnimation(Motion.spring) { cardsVisible = true; browser.tabGridCoversPage = true }
            } landed: {
                instantly { heroID = nil }
                flight.land()
            }
        }
    }

    /// Grows `tab`'s card back to fill the page and leaves the grid. The page switches to `tab`
    /// only once the picture covers it, and the picture stays until the page has drawn.
    private func close(into tab: BrowserTab?) {
        // The tabs button turns back from the tick as you pick, not when the page lands, so it's
        // ready to open the gallery again straight away.
        if let tab { closingInto = tab }
        if browser.isTabSwitcherPresented { browser.isTabSwitcherPresented = false }
        guard let tab, let card = cardFrames.byTab[tab.id], pageRect != .zero,
              let window = liveWebView?.window ?? flight.window,
              let picture = tab.id == browser.currentTab?.id
                ? (liveWebView.flatMap(ZoomFlight.snapshot(of:)) ?? browser.thumbnails[tab.id])
                : browser.thumbnails[tab.id] else {
            if let tab { browser.select(tab) }
            withAnimation(Motion.snappy) {
                cardsVisible = false
                shown = false
                browser.tabGridCoversPage = false
            } completion: { finish() }
            return
        }
        // A tab that hasn't been open since launch doesn't know its page colour yet. Its picture
        // does, so the colour beside the page can blend to it during the zoom.
        if tab.pageBackground == nil { tab.pageBackground = ZoomFlight.edgeColor(of: picture) }
        flight.start(picture, in: window, at: card, cornerRadius: TabGridCard.cornerRadius)
        let picked = flight.generation
        instantly { heroID = tab.id }
        flight.fly(to: pageRect, cornerRadius: 0) {
            withAnimation(Motion.spring) {
                cardsVisible = false
                browser.tabGridLandingTab = tab
                browser.tabGridCoversPage = false
            }
        } landed: {
            let switching = tab.id != browser.currentTab?.id
            instantly {
                browser.select(tab)
                finish(keepingAddressBarHidden: true)
            }
            Task { @MainActor in
                // A tab that wasn't on screen needs a moment to draw. Keep its picture over it
                // until it has, so there's never a blank page.
                if switching {
                    var waited = 0
                    while waited < 40, tab.isAwaitingFirstPaint || browser.session(for: tab).webView.window == nil {
                        try? await Task.sleep(for: .milliseconds(25))
                        waited += 1
                    }
                }
                // A frame or so for the page to be on screen under the picture.
                try? await Task.sleep(for: .milliseconds(switching ? 50 : 16))
                guard flight.generation == picked else { return }
                flight.fadeOut(generation: picked)
                // The address bar comes in as the picture gives way to the page, rather than
                // appearing the moment the picture goes.
                withAnimation(Motion.spring) { browser.tabGridHidesAddressBar = false }
            }
        }
    }

    private func instantly(_ change: () -> Void) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t, change)
    }

    private func finish(resettingButton: Bool = true, keepingAddressBarHidden: Bool = false) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            closingInto = nil
            shown = false
            cardsVisible = false
            heroID = nil
            browser.tabGridCoversPage = false
            browser.tabGridLandingTab = nil
            if !keepingAddressBarHidden { browser.tabGridHidesAddressBar = false }
        }
        if resettingButton, browser.isTabSwitcherPresented { browser.isTabSwitcherPresented = false }
    }

    private func tab(_ id: UUID) -> BrowserTab? { browser.currentSpace.allTabs.first { $0.id == id } }

    // MARK: Grid

    /// Cards have the page's shape, so its picture fits a card exactly.
    private var aspect: CGFloat {
        let size = pageRect == .zero ? overlaySize : pageRect.size
        return max(0.4, min(2, size.width / max(size.height, 1)))
    }

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
        .opacity(cardsVisible ? 1 : 0)   // stays laid out so the picture has a card to fly to
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

    /// Just the space switcher. The vertical bar's tabs button (a tick while the gallery is up)
    /// closes the gallery, and its plus opens a new tab, so neither is repeated here.
    private var bottomBar: some View {
        Menu {
            ForEach(browser.spaces) { s in
                Button { withAnimation(Motion.snappy) { browser.selectSpace(s) } } label: {
                    Label(s.name, systemImage: s.symbol)
                }
            }
            if browser.privateSpace != nil {
                Divider()
                Button("Close Private Tabs", systemImage: "xmark", role: .destructive) {
                    withAnimation(Motion.snappy) { browser.closePrivateSpace() }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: browser.currentSpace.symbol).font(.subheadline)
                Text(browser.currentSpace.name).fontWeight(.semibold)
                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .accessibilityLabel("Space, \(browser.currentSpace.name)")
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}
