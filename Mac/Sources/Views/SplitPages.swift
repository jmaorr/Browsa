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
                    SplitPane(tab: tab, index: i, count: tabs.count, isFront: tab.id == browser.currentTab?.id)
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
        }
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

/// One pane: a page card that comes to the front when clicked. Its actions sit behind a small
/// handle that only shows while the pointer is near the pane's top edge, so it's out of the way
/// the rest of the time.
private struct SplitPane: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab
    let index: Int
    let count: Int
    let isFront: Bool
    @State private var nearTop = false

    /// How far down from the pane's top edge the handle appears.
    private static let revealDepth: CGFloat = 44

    var body: some View {
        PageCardView(tab: tab, isFront: isFront, inSplit: true)
            // The pane in front gets a quiet outline, so it's clear which one the keys go to.
            .overlay {
                RoundedRectangle(cornerRadius: PageCard.radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFront ? 0.28 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if nearTop {
                    PaneHandle(tab: tab, index: index, count: count)
                        .padding(.top, 6)
                        .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .top)))
                }
            }
            .background(PaneClickWatcher { if !isFront { browser.select(tab) } })
            .onContinuousHover { phase in
                let near: Bool
                if case .active(let point) = phase { near = point.y < Self.revealDepth } else { near = false }
                if near != nearTop { withAnimation(Motion.snappy) { nearTop = near } }
            }
            .animation(Motion.snappy, value: isFront)
    }
}

/// A pane's handle: a small glass capsule that opens the pane's menu (move left or right, leave
/// the split, close). The same items are in the tab's right-click menu in the sidebar.
private struct PaneHandle: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab
    let index: Int
    let count: Int

    var body: some View {
        Menu {
            if index > 0 {
                Button("Move Left", systemImage: "arrow.left") { act { browser.shiftPane(tab, by: -1) } }
            }
            if index < count - 1 {
                Button("Move Right", systemImage: "arrow.right") { act { browser.shiftPane(tab, by: 1) } }
            }
            Button("Even Up Panes", systemImage: "equal") { act { browser.evenSplit(browser.rowTabs(tab)) } }
            Divider()
            Button("Remove from Split View", systemImage: "rectangle.portrait.and.arrow.right") { act { browser.removeFromSplit(tab) } }
            Button(tab.isPinned ? "Unload Tab" : "Close Tab", systemImage: tab.isPinned ? "minus" : "xmark") { act { browser.close(tab) } }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 18)
                .contentShape(.capsule)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .background(PanelFill(), in: .capsule)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .help("Split View options")
    }

    private func act(_ action: () -> Void) {
        withAnimation(Motion.snappy) { action() }
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

/// A split in the sidebar: its tabs side by side in one row, like the panes. Click a tab to bring
/// its pane to the front; each tab keeps its own menu.
struct SplitTabRow: View {
    @Environment(Browser.self) private var browser
    let tabs: [BrowserTab]
    let selected: Bool
    var isLifted = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                if i > 0 {
                    Rectangle()
                        .fill(.primary.opacity(0.14))
                        .frame(width: 1, height: 16)
                }
                SplitTabSegment(tab: tab, isFront: selected && browser.currentTab?.id == tab.id, rowSelected: selected)
            }
            if hovering, !isLifted {
                Button { withAnimation(Motion.snappy) { browser.closeSplit(containing: tabs[0]) } } label: {
                    Image(systemName: tabs[0].isPinned ? "minus" : "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(.primary.opacity(0.08), in: .rect(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.trailing, 6)
                .help(tabs[0].isPinned ? "Unload Split View" : "Close Split View")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 2)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AnyShapeStyle(SelectedFill()) : AnyShapeStyle(.primary.opacity(hovering ? 0.06 : 0)))
                .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1.5, y: 1)
        }
        .contentShape(.rect)
        .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split View")
    }
}

private struct SplitTabSegment: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab
    let isFront: Bool
    let rowSelected: Bool

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
            if let call = tab.call { CallBadge(call: call) }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onTapGesture { browser.select(tab) }
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
