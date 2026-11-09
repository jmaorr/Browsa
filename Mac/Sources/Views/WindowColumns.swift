import SwiftUI
import AppKit
import WebKit

/// The window's three columns, sidebar | page | panel, on AppKit's split view.
///
/// Resizing a column moves frames directly, at the display's frame rate, with no SwiftUI layout
/// pass in between. While a divider drags, the web views are told a live resize is under way, the
/// same signal a window resize gives them, so the page reflows the way it does then.
/// Each column's content is still SwiftUI.
struct WindowColumns: NSViewControllerRepresentable {
    let browser: Browser
    /// Passed in, rather than read inside, so a change reaches `updateNSViewController`.
    let sidebarDocked: Bool
    let panelOpen: Bool

    func makeNSViewController(context: Context) -> ColumnsController {
        ColumnsController(browser: browser, sidebarDocked: sidebarDocked, panelOpen: panelOpen)
    }

    func updateNSViewController(_ controller: ColumnsController, context: Context) {
        controller.setSidebar(docked: sidebarDocked)
        controller.setPanel(open: panelOpen)
    }
}

final class ColumnsController: NSSplitViewController {
    private let browser: Browser
    private let sidebarItem: NSSplitViewItem
    private let pageItem: NSSplitViewItem
    private let panelItem: NSSplitViewItem
    private var startsDocked: Bool
    private var startsOpen: Bool
    private var placed = false

    init(browser: Browser, sidebarDocked: Bool, panelOpen: Bool) {
        self.browser = browser
        startsDocked = sidebarDocked
        startsOpen = panelOpen
        sidebarItem = NSSplitViewItem(viewController: Self.host(Sidebar(), browser))
        pageItem = NSSplitViewItem(viewController: Self.host(PageColumn(), browser))
        panelItem = NSSplitViewItem(viewController: Self.host(PanelColumn(), browser))
        super.init(nibName: nil, bundle: nil)

        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 420
        // The page takes up a window resize; the side columns keep their widths.
        sidebarItem.holdingPriority = .init(260)
        pageItem.holdingPriority = .init(240)
        pageItem.minimumThickness = 320
        panelItem.canCollapse = true
        panelItem.minimumThickness = 240
        panelItem.maximumThickness = 560
        // Between the page's and the sidebar's: with the sidebar's priority, dragging the panel's divider
        // couldn't widen it (the panel slid over, leaving an empty strip at the window edge, then snapped
        // back). Still above the page's, so a window resize goes to the page.
        panelItem.holdingPriority = .init(250)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func host<V: View>(_ view: V, _ browser: Browser) -> NSViewController {
        let host = NSHostingController(rootView: view.environment(browser).environment(browser.library)
            .ignoresSafeArea())
        // The split view sets the frames; SwiftUI mustn't add size constraints of its own.
        host.sizingOptions = []
        // Each hosting view would otherwise inset its content by the transparent title bar, which
        // pushes the columns down and leaves a gap above the traffic-light row.
        host.safeAreaRegions = []
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        return host
    }

    override func loadView() {
        let split = ColumnsSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.pageView = { [weak self] in self?.pageItem.viewController.view }
        split.onDragEnded = { [weak self] moved in if moved { self?.saveWidths() } }
        splitView = split
        super.loadView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addSplitViewItem(sidebarItem)
        addSplitViewItem(pageItem)
        addSplitViewItem(panelItem)
    }

    /// Sets the saved widths once there's a size to set them in, then collapses what starts closed.
    /// Collapsed columns come back at the width they had, so both are placed open first.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !placed, splitView.bounds.width > 0 else { return }
        placed = true
        splitView.setPosition(browser.sidebarWidth, ofDividerAt: 0)
        splitView.setPosition(splitView.bounds.width - browser.panelWidth - splitView.dividerThickness, ofDividerAt: 1)
        sidebarItem.isCollapsed = !startsDocked
        panelItem.isCollapsed = !startsOpen
    }

    func setSidebar(docked: Bool) {
        startsDocked = docked
        guard placed else { return }
        animate(sidebarItem, collapsed: !docked)
    }

    func setPanel(open: Bool) {
        startsOpen = open
        guard placed else { return }
        animate(panelItem, collapsed: !open)
    }

    /// An interrupted animation (another toggle, a layout pass) can leave a column where it was: put
    /// both on what the app now wants.
    /// An open column also gets its saved width back, which an interrupted collapse can shrink.
    private func settle() {
        for item in [sidebarItem, panelItem] where item.isCollapsed != wantsCollapsed(item) {
            item.isCollapsed = wantsCollapsed(item)
        }
        if !sidebarItem.isCollapsed, abs(sidebarItem.viewController.view.frame.width - browser.sidebarWidth) > 1 {
            splitView.setPosition(browser.sidebarWidth, ofDividerAt: 0)
        }
        if !panelItem.isCollapsed, abs(panelItem.viewController.view.frame.width - browser.panelWidth) > 1 {
            splitView.setPosition(splitView.bounds.width - browser.panelWidth - splitView.dividerThickness, ofDividerAt: 1)
        }
    }

    /// Whether `item` should be collapsed, from the app's state (not from the split view, which can be
    /// mid-animation).
    private func wantsCollapsed(_ item: NSSplitViewItem) -> Bool {
        item === sidebarItem ? !startsDocked : !startsOpen
    }

    private func animate(_ item: NSSplitViewItem, collapsed: Bool) {
        guard item.isCollapsed != collapsed else { return }
        let webViews = (splitView as? ColumnsSplitView)?.beginLiveResize() ?? []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Motion.dockDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            item.animator().isCollapsed = collapsed
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                ColumnsSplitView.endLiveResize(webViews)
                self?.settle()
            }
        }
    }

    private func saveWidths() {
        if !sidebarItem.isCollapsed { browser.sidebarWidth = sidebarItem.viewController.view.frame.width }
        if !panelItem.isCollapsed { browser.panelWidth = panelItem.viewController.view.frame.width }
        // Dragged shut past the minimum: the app's state follows.
        if sidebarItem.isCollapsed == browser.isSidebarDocked { browser.toggleSidebar() }
        if panelItem.isCollapsed, browser.panel != nil { browser.panel = nil }
    }

    // MARK: Split view delegate


    /// Collapsed columns keep their divider: it's the gap between the page and the window edge.
    override func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { false }

    /// A collapsed column's divider can't be dragged open; the buttons and shortcuts open it.
    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let neighbour = dividerIndex == 0 ? sidebarItem : panelItem
        if neighbour.isCollapsed { return .zero }
        // A little wider than drawn, so the edge is easy to catch.
        return proposedEffectiveRect.insetBy(dx: -3, dy: 0)
    }
}

/// The split view itself: clear dividers as wide as the gap around the page, and live-resize
/// signalling to the web views while one drags.
final class ColumnsSplitView: NSSplitView {
    var pageView: () -> NSView? = { nil }
    /// After a click on a divider: whether it actually moved anything.
    var onDragEnded: (_ moved: Bool) -> Void = { _ in }

    override var dividerThickness: CGFloat { PageCard.inset }
    override var dividerColor: NSColor { .clear }
    override func drawDivider(in rect: NSRect) {}

    /// NSSplitView tracks a divider drag inside `mouseDown`, so this brackets the whole drag.
    override func mouseDown(with event: NSEvent) {
        let webViews = beginLiveResize()
        let before = subviews.map(\.frame)
        super.mouseDown(with: event)
        Self.endLiveResize(webViews)
        // A plain click on a divider (or the gap around the page) mustn't touch the app's state.
        onDragEnded(subviews.map(\.frame) != before)
    }

    /// Tells every web view in the page column that a live resize has started, like a window resize.
    func beginLiveResize() -> [NSView] {
        guard let root = pageView() else { return [] }
        let webViews = Self.webViews(in: root)
        webViews.forEach { $0.viewWillStartLiveResize() }
        return webViews
    }

    static func endLiveResize(_ webViews: [NSView]) {
        webViews.forEach { $0.viewDidEndLiveResize() }
    }

    private static func webViews(in view: NSView) -> [NSView] {
        if view is WKWebView { return [view] }
        return view.subviews.flatMap(webViews)
    }
}

// MARK: - Columns

/// The page, with the gap above and below it. The dividers make the gaps at its sides.
private struct PageColumn: View {
    @Environment(Browser.self) private var browser

    var body: some View {
        PageArea()
            .background(PageCardMarker(browser: browser))
            .padding(.vertical, PageCard.inset)
    }
}

/// The right panel's column. It keeps showing the last tool while it slides shut.
private struct PanelColumn: View {
    @Environment(Browser.self) private var browser
    @State private var lastTool = Preferences.lastPanelTool

    var body: some View {
        RightPanel(toolID: browser.panel ?? lastTool)
            .padding(.vertical, PageCard.inset)
            .padding(.trailing, PageCard.inset)
            .onChange(of: browser.panel) { _, new in if let new { lastTool = new } }
    }
}
