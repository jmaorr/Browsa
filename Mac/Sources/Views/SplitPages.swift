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
    @State private var liveWebViews: [NSView] = []

    private static let minimumPane: CGFloat = 240

    var body: some View {
        GeometryReader { geo in
            let gap = PageCard.inset
            let available = max(1, geo.size.width - gap * CGFloat(tabs.count - 1))
            let widths = browser.splitWidths(tabs)
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { i, tab in
                    SplitPane(tab: tab, index: i, count: tabs.count, isFront: tab.id == browser.currentTab?.id)
                        .frame(width: max(0, available * widths[i]))
                    if i < tabs.count - 1 {
                        SplitDivider()
                            .frame(width: gap)
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { drag(i, by: $0.translation.width, available: available) }
                                .onEnded { _ in endDrag() })
                            .onTapGesture(count: 2) { withAnimation(Motion.snappy) { browser.evenSplit(tabs) } }
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
        browser.setSplitWidths(widths, for: tabs)
    }

    private func endDrag() {
        dragStart = nil
        liveWebViews.forEach { $0.viewDidEndLiveResize() }
        liveWebViews = []
    }
}

/// One pane: a page card that comes to the front when clicked, with a small glass capsule of pane
/// actions while the pointer is over it.
private struct SplitPane: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab
    let index: Int
    let count: Int
    let isFront: Bool
    @State private var hovering = false

    var body: some View {
        PageCardView(tab: tab, isFront: isFront, inSplit: true)
            // The pane in front gets a quiet outline, so it's clear which one the keys go to.
            .overlay {
                RoundedRectangle(cornerRadius: PageCard.radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFront ? 0.28 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if hovering {
                    PaneControls(tab: tab, index: index, count: count)
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(PaneClickWatcher { if !isFront { browser.select(tab) } })
            .onHover { h in withAnimation(Motion.snappy) { hovering = h } }
            .animation(Motion.snappy, value: isFront)
    }
}

/// What a pane can do: move left or right, leave the split, close.
private struct PaneControls: View {
    @Environment(Browser.self) private var browser
    let tab: BrowserTab
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            if index > 0 {
                button("arrow.left", "Move Left") { browser.shiftPane(tab, by: -1) }
            }
            if index < count - 1 {
                button("arrow.right", "Move Right") { browser.shiftPane(tab, by: 1) }
            }
            button("rectangle.portrait.and.arrow.right", "Remove from Split View") { browser.removeFromSplit(tab) }
            button(tab.isPinned ? "minus" : "xmark", tab.isPinned ? "Unload Tab" : "Close Tab") { browser.close(tab) }
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
        .background(PanelFill(), in: .capsule)
        .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button { withAnimation(Motion.snappy) { action() } } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// The gap between two panes: clear, with the resize cursor.
private struct SplitDivider: View {
    @State private var hovering = false

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .onHover { h in
                guard h != hovering else { return }
                hovering = h
                if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
            .help("Drag to resize. Double-click to even up.")
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
