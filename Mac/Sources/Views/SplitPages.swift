import SwiftUI
import AppKit
import WebKit
import BrowserCore

// MARK: - Page column

/// Split View's page column: two or three page cards side by side, with the window's usual gap
/// between them. The gaps are dividers you can drag (double-click one to even the panes up).
/// Clicking into a pane brings it to the front: the address bar, find, Reader and ⌘W act on it.
struct SplitPages: View {
    @Environment(Browser.self) private var browser
    let tabs: [BrowserTab]
    /// The pane widths when a divider drag started.
    @State private var dragStart: [Double]?
    /// The widths while a divider is dragged. Kept here and saved once when the drag ends, so the
    /// sidebar and everything else watching splits doesn't redraw on every frame of the drag.
    @State private var liveWidths: [Double]?
    @State private var liveWebViews: [NSView] = []
    /// The pane whose handle shows: the one the pointer is near the top of. One at a time.
    @State private var handlePane: Int?
    /// The pane whose control panel is open. Its handle stays out whatever the pointer does.
    @State private var panelPane: Int?

    private static let minimumPane: CGFloat = 240
    /// How far the divider's grab zone reaches over each pane, past the visible gap.
    static let grabOverhang: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let gap = PageCard.inset
            let available = max(1, geo.size.width - gap * CGFloat(tabs.count - 1))
            let widths = liveWidths.flatMap { $0.count == tabs.count ? $0 : nil } ?? browser.splitWidths(tabs)
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                    SplitPane(tab: tab, index: i, count: tabs.count, isFront: tab.id == browser.currentTab?.id,
                              showsHandle: handlePane == i || panelPane == i,
                              panelOpen: Binding(get: { panelPane == i }, set: { open in
                                  withAnimation(Motion.snappy) {
                                      if open { panelPane = i } else if panelPane == i { panelPane = nil }
                                  }
                              }))
                        .frame(width: max(0, available * widths[i]))
                    if i < tabs.count - 1 {
                        // The gap is only 6pt, so the grab zone reaches a few points over each
                        // pane's edge, and sits above the pages so they can't take the cursor.
                        Color.clear
                            .frame(width: gap)
                            .overlay {
                                SplitDivider(
                                    onDrag: { drag(i, by: $0, available: available) },
                                    onEnd: endDrag,
                                    onDoubleClick: { withAnimation(Motion.snappy) { browser.evenSplit(tabs) } })
                                    .frame(width: gap + Self.grabOverhang * 2)
                            }
                            .zIndex(1)
                    }
                }
            }
            // One watcher for the whole split decides which handle shows. Hover tracking per pane
            // over the web views misses moves and sticks; an AppKit tracking area doesn't.
            .overlay {
                SplitHoverTracker { point in
                    let pane = point.flatMap { p in
                        p.y < Self.handleDepth ? paneIndex(atX: p.x, widths: widths, available: available, gap: gap) : nil
                    }
                    if pane != handlePane { withAnimation(Motion.snappy) { handlePane = pane } }
                }
            }
            .onChange(of: tabs.map(\.id)) { panelPane = nil; handlePane = nil }
        }
    }

    /// How far down from a pane's top edge its handle appears.
    private static let handleDepth: CGFloat = 44

    /// The pane under `x`, or nil over a gap.
    private func paneIndex(atX x: CGFloat, widths: [Double], available: CGFloat, gap: CGFloat) -> Int? {
        var left: CGFloat = 0
        for (i, w) in widths.enumerated() {
            let right = left + available * w
            if x >= left && x < right { return i }
            left = right + gap
        }
        return nil
    }

    /// Moves the line between pane `i` and the next: one grows as much as the other shrinks.
    private func drag(_ i: Int, by dx: CGFloat, available: CGFloat) {
        if dragStart == nil {
            dragStart = browser.splitWidths(tabs)
            liveWebViews = tabs.compactMap { browser.library.existingController(for: $0)?.page.view }
            // As with a window resize, so the pages reflow the way they do then.
            liveWebViews.forEach { $0.viewWillStartLiveResize() }
        }
        guard var widths = dragStart else { return }
        let pair = widths[i] + widths[i + 1]
        let least = min(pair / 2, Double(Self.minimumPane / available))
        let left = min(max(widths[i] + Double(dx / available), least), pair - least)
        widths[i] = left
        widths[i + 1] = pair - left
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { liveWidths = widths }
    }

    private func endDrag() {
        if let liveWidths { browser.setSplitWidths(liveWidths, for: tabs) }
        liveWidths = nil
        dragStart = nil
        liveWebViews.forEach { $0.viewDidEndLiveResize() }
        liveWebViews = []
    }
}

/// One pane: a page card that comes to the front when clicked. Its controls sit behind a small
/// handle that shows while the pointer is near the pane's top edge (SplitPages decides), and open
/// into a glass panel when it's clicked.
private struct SplitPane: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab
    let index: Int
    let count: Int
    let isFront: Bool
    let showsHandle: Bool
    @Binding var panelOpen: Bool

    var body: some View {
        PageCardView(tab: tab, isFront: isFront, inSplit: true)
            // The pane in front gets a quiet outline, so it's clear which one the keys go to.
            .overlay {
                RoundedRectangle(cornerRadius: PageCard.radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFront ? 0.28 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if showsHandle {
                    PaneControls(tab: tab, index: index, count: count, open: $panelOpen)
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .top)))
                }
            }
            .background(PaneClickWatcher { if !isFront { browser.select(tab) } })
            .animation(Motion.snappy, value: isFront)
    }
}

/// A pane's controls: a small glass grip that morphs into a glass panel hanging from the top of
/// the pane. The panel has the page's controls (back, forward, reload, and the address with its
/// copy link, site menu and extensions) and the pane's Split View actions. Escape or a click
/// outside it morphs it back.
private struct PaneControls: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab
    let index: Int
    let count: Int
    @Binding var open: Bool
    @Namespace private var glass

    static let panelWidth: CGFloat = 340

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            if open {
                panel
                    .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
                    .glassEffectID("controls", in: glass)
                    .background(OutsideClickWatcher { open = false })
            } else {
                Button {
                    // The panel's address and page buttons act on the tab in front.
                    if !isFront { browser.select(tab) }
                    open = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 18)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("controls", in: glass)
                .help("Page and Split View controls")
            }
        }
        // Whatever takes the front pane away from this tab closes the panel: its address would
        // show another page.
        .onChange(of: browser.currentTab?.id) { _, id in if open, id != tab.id { open = false } }
        .onChange(of: browser.commandBar != nil) { _, showing in if showing { open = false } }
    }

    private var isFront: Bool { browser.currentTab?.id == tab.id }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Page")
            HStack(spacing: 6) {
                glassButton("chevron.left", "Back", enabled: tab.canGoBack) { browser.goBack() }
                glassButton("chevron.right", "Forward", enabled: tab.canGoForward) { browser.goForward() }
                glassButton(tab.isLoading ? "xmark" : "arrow.clockwise", tab.isLoading ? "Stop" : "Reload") {
                    if tab.isLoading { browser.stopLoading() } else { browser.reload() }
                }
                Spacer(minLength: 0)
            }
            AddressPill()
            section("Split View").padding(.top, 4)
            HStack(spacing: 6) {
                glassButton("arrow.left", "Move Left", enabled: index > 0) { act { browser.shiftPane(tab, by: -1) } }
                glassButton("arrow.right", "Move Right", enabled: index < count - 1) { act { browser.shiftPane(tab, by: 1) } }
                glassButton("equal", "Even Up Panes") { act { browser.evenSplit(browser.rowTabs(tab)) } }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                labeledButton("rectangle.portrait.and.arrow.right", "Remove from Split") { act { browser.removeFromSplit(tab) } }
                labeledButton(tab.isPinned ? "minus" : "xmark", tab.isPinned ? "Unload Tab" : "Close Tab") { act { browser.close(tab) } }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(width: Self.panelWidth, alignment: .leading)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func glassButton(_ symbol: String, _ help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18, height: 16)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .disabled(!enabled)
        .help(help)
    }

    private func labeledButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
    }

    private func act(_ action: () -> Void) {
        withAnimation(Motion.snappy) {
            open = false
            action()
        }
    }
}

/// Tells SplitPages where the pointer is over the split (top-left origin), or nil once it leaves.
/// A tracking area reaches its owner wherever the pointer is in its rect, whatever view is on
/// top, so the pages can't swallow the moves. Never takes a click.
private struct SplitHoverTracker: NSViewRepresentable {
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> Tracker {
        let view = Tracker()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: Tracker, context: Context) { view.onMove = onMove }

    final class Tracker: NSView {
        var onMove: (CGPoint?) -> Void = { _ in }

        override var isFlipped: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { report(event) }
        override func mouseMoved(with event: NSEvent) { report(event) }
        override func mouseDragged(with event: NSEvent) { report(event) }
        override func mouseExited(with event: NSEvent) { onMove(nil) }

        private func report(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onMove(bounds.contains(point) ? point : nil)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Calls back on Escape, or a click anywhere outside this view's frame, while it's on screen.
/// The click still goes where it was headed.
private struct OutsideClickWatcher: NSViewRepresentable {
    let onOutside: () -> Void

    func makeNSView(context: Context) -> Watcher {
        let view = Watcher()
        view.onOutside = onOutside
        return view
    }

    func updateNSView(_ view: Watcher, context: Context) { view.onOutside = onOutside }

    static func dismantleNSView(_ view: Watcher, coordinator: ()) { view.stop() }

    final class Watcher: NSView {
        var onOutside: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                let isEscape = event.type == .keyDown && event.keyCode == 53
                if event.type == .keyDown && !isEscape { return event }
                let location = event.locationInWindow
                let eventWindow = event.window
                // A click in a menu or popup window from inside the panel isn't outside it.
                let swallow = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, eventWindow === window else { return false }
                    if isEscape { self.onOutside(); return true }
                    if !self.bounds.contains(self.convert(location, from: nil)) { self.onOutside() }
                    return false
                }
                return swallow ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The gap between two panes, as an AppKit view on top of the pages: it owns the resize cursor
/// (a page under the pointer can't reset it) and the drag, so the drag stays steady while the
/// panes reflow. A thin grabber shows in the gap while the pointer is on it.
private struct SplitDivider: NSViewRepresentable {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> Handle {
        let view = Handle()
        update(view)
        return view
    }

    func updateNSView(_ view: Handle, context: Context) { update(view) }

    private func update(_ view: Handle) {
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onDoubleClick = onDoubleClick
    }

    final class Handle: NSView {
        var onDrag: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onDoubleClick: () -> Void = {}
        private var startX: CGFloat?
        private let grabber = CALayer()
        private var hovering = false { didSet { updateGrabber() } }
        private var dragging = false { didSet { updateGrabber() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            grabber.cornerRadius = 1.5
            grabber.opacity = 0
            layer?.addSublayer(grabber)
            toolTip = "Drag to resize. Double-click to even up."
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let height = min(44, bounds.height / 3)
            grabber.frame = CGRect(x: bounds.midX - 1.5, y: bounds.midY - height / 2, width: 3, height: height)
            CATransaction.commit()
        }

        override func updateLayer() {
            grabber.backgroundColor = NSColor.secondaryLabelColor.cgColor
        }

        private func updateGrabber() {
            grabber.opacity = (hovering || dragging) ? (dragging ? 0.8 : 0.5) : 0
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseEntered(with event: NSEvent) { hovering = true }
        override func mouseExited(with event: NSEvent) { hovering = false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onDoubleClick(); return }
            startX = event.locationInWindow.x
            dragging = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            NSCursor.resizeLeftRight.set()
            onDrag(event.locationInWindow.x - startX)
        }

        override func mouseUp(with event: NSEvent) {
            guard startX != nil else { return }
            startX = nil
            dragging = false
            onEnd()
        }
    }
}

/// Calls back when a click lands inside this view's frame, without taking the click: the page
/// under it still gets it. A web view handles its own clicks, so watching for them is the only way
/// to know a pane was clicked.
private struct PaneClickWatcher: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> Watcher {
        let view = Watcher()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: Watcher, context: Context) { view.onClick = onClick }

    static func dismantleNSView(_ view: Watcher, coordinator: ()) { view.stop() }

    final class Watcher: NSView {
        var onClick: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, event.window === window, !self.isHiddenOrHasHiddenAncestor else { return }
                    let point = self.convert(event.locationInWindow, from: nil)
                    if self.bounds.contains(point) { self.onClick() }
                }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        // Never in the way of the page above it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Sidebar

/// A sidebar row: one tab, or a whole split as one row.
struct SidebarRow: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab
    let selected: Bool
    var isLifted = false

    var body: some View {
        let tabs = browser.rowTabs(tab)
        if tabs.count > 1 {
            SplitTabRow(tabs: tabs, selected: selected || tabs.contains { browser.currentTab?.id == $0.id }, isLifted: isLifted)
        } else {
            TabRow(tab: tab, selected: selected, isLifted: isLifted)
        }
    }
}

/// A split in the sidebar: a box holding one smaller box per tab, side by side like the panes.
/// Click a tab's box to bring its pane to the front; each has its own close and menu. A little
/// taller than a tab row, so the box in a box reads.
struct SplitTabRow: View {
    @Environment(Browser.self) private var browser
    let tabs: [BrowserTab]
    let selected: Bool
    var isLifted = false
    @State private var hovering = false

    static let height: CGFloat = 40
    static let padding: CGFloat = 3

    var body: some View {
        HStack(spacing: Self.padding) {
            ForEach(tabs) { tab in
                SplitTabSegment(tab: tab, isFront: selected && browser.currentTab?.id == tab.id,
                                rowSelected: selected, canClose: !isLifted)
            }
        }
        .font(.system(size: 13))
        .padding(Self.padding)
        .frame(height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.primary.opacity(selected ? 0.09 : (hovering ? 0.07 : 0.045)))
        }
        .contentShape(.rect)
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split View")
    }
}

/// One tab's box in a split's sidebar row. The pane in front gets the strongest fill.
private struct SplitTabSegment: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab
    let isFront: Bool
    let rowSelected: Bool
    var canClose = true
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                TabIcon(tab: tab, size: 16)
                    .opacity(tab.isLoading && tab.estimatedProgress < 0.5 ? 0.35 : 1)
                if tab.isLoading && tab.estimatedProgress < 0.5 { ProgressView().controlSize(.mini) }
            }
            .frame(width: 16, height: 16)
            Text(tab.displayTitle)
                .lineLimit(1)
                // In the selected row, the tab in front reads a little stronger than the others.
                .foregroundStyle(rowSelected && !isFront ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.primary)
            Spacer(minLength: 0)
            if let call = tab.call { CallBadge(call: call) }
            if hovering, canClose {
                Button { withAnimation(Motion.snappy) { browser.close(tab) } } label: {
                    Image(systemName: tab.isPinned ? "minus" : "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Shortcuts.shared.help(tab.isPinned ? "Unload Tab" : "Close Tab", .close))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFront ? AnyShapeStyle(SelectedFill()) : AnyShapeStyle(.primary.opacity(hovering ? 0.07 : 0.035)))
                .shadow(color: .black.opacity(isFront ? 0.1 : 0), radius: 1.5, y: 1)
        }
        .contentShape(.rect)
        .onTapGesture { browser.select(tab) }
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
        .contextMenu { TabMenu(tab: tab) }
        .help(tab.url?.absoluteString ?? tab.displayTitle)
    }
}

/// A tab's Split View items, in its sidebar menu.
struct SplitViewMenuItems: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab

    var body: some View {
        if browser.rowTabs(tab).count > 1 {
            Button("Remove from Split View", systemImage: "rectangle.portrait.and.arrow.right") {
                withAnimation(Motion.snappy) { browser.removeFromSplit(tab) }
            }
            Button("Separate Split View", systemImage: "rectangle.split.2x1") {
                withAnimation(Motion.snappy) { browser.separateSplit(containing: tab) }
            }
        } else if browser.canSplit(with: tab) {
            Button(browser.isSplit ? "Add to Split View" : "Open in Split View", systemImage: "rectangle.split.2x1") {
                withAnimation(Motion.snappy) { browser.openInSplit(tab) }
            }
        }
    }
}
