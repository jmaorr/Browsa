import AppKit
import SwiftUI
import Observation
import BrowserCore

/// Picture in picture for calls. WebKit has no Document Picture-in-Picture (what Meet's own PiP button uses in
/// Chrome), so Browsa does it itself: when you leave a call's tab, the call's live page moves into a small floating
/// window that stays over every app and Space, scaled down so the call keeps its normal layout. Its own buttons
/// (mute, camera, leave) still work. Going back to the tab, from the window's button or anywhere else, puts the
/// page back. Closing the window leaves the capsule over the page (`CallCapsule`) as the way back.
///
/// Set `callPiP` to false in the defaults to turn it off.
@MainActor
final class CallPiP {
    private static var shared: CallPiP?

    static func install(in library: Library) {
        UserDefaults.standard.register(defaults: ["callPiP": true])
        let pip = CallPiP(library: library)
        shared = pip
        pip.track()
    }

    /// The page is laid out at this multiple of the window's size, then scaled down to fit.
    private static let scale = 0.5
    private static let defaultSize = NSSize(width: 360, height: 255)
    private static let frameKey = "callPiPFrame"

    private unowned let library: Library
    private var panel: CallPiPPanel?
    /// The tab floating now, and the page zoom it had before.
    private var floating: (tab: BrowserTab, zoom: Double)?

    private init(library: Library) {
        self.library = library
    }

    /// The call to float: a tab in a call that no window is showing, unless you closed its window.
    private func target() -> BrowserTab? {
        guard UserDefaults.standard.bool(forKey: "callPiP") else { return nil }
        return library.allTabs
            .filter { $0.call != nil && $0.id != library.pipClosedFor && library.window(showing: $0) == nil }
            .max { $0.lastActive < $1.lastActive }
    }

    private func track() {
        let tab = withObservationTracking { target() } onChange: { [weak self] in
            // After the change lands, so a window showing the tab again has taken its page back first.
            Task { @MainActor in self?.track() }
        }
        update(to: tab)
    }

    private func update(to tab: BrowserTab?) {
        // A call that ended no longer needs closing for.
        if let closed = library.pipClosedFor, !library.allTabs.contains(where: { $0.id == closed && $0.call != nil }) {
            library.pipClosedFor = nil
        }
        if floating?.tab.id == tab?.id { return }
        putBack()
        if let tab { float(tab) }
    }

    private func float(_ tab: BrowserTab) {
        guard let controller = library.existingController(for: tab) else { return }
        guard let page = controller.page else { return }
        let panel = self.panel ?? makePanel()
        floating = (tab, page.zoom)
        page.zoom = Self.scale
        panel.show(page.view, tab: tab,
                   back: { [weak self] in self?.goBack(to: tab) },
                   close: { [weak self] in self?.library.pipClosedFor = tab.id })
        library.pipTabID = tab.id
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Gives the page back to its tab (a window takes it when it shows the tab) and hides the window.
    private func putBack() {
        guard let current = floating else { return }
        floating = nil
        if let page = library.existingController(for: current.tab)?.page {
            page.zoom = current.zoom
            panel?.release(page.view)
        }
        library.pipTabID = nil
        if let panel {
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
            panel.orderOut(nil)
        }
    }

    private func goBack(to tab: BrowserTab) {
        guard let window = library.owner(of: tab) ?? library.activeWindow else { return }
        window.select(tab)
        window.nsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makePanel() -> CallPiPPanel {
        var frame = NSRectFromString(UserDefaults.standard.string(forKey: Self.frameKey) ?? "")
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        if frame.width < 200 || screen == nil {
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            frame = NSRect(x: visible.maxX - Self.defaultSize.width - 16, y: visible.minY + 16,
                           width: Self.defaultSize.width, height: Self.defaultSize.height)
        }
        let panel = CallPiPPanel(frame: frame, scale: Self.scale)
        self.panel = panel
        return panel
    }
}

/// The floating window: a bar along the top to move it, go back or close it, and the call's page under it.
@MainActor
final class CallPiPPanel: NSPanel {
    private let pageSlot = NSView()
    private let bar = NSHostingView(rootView: AnyView(EmptyView()))
    private let scale: Double
    private static let barHeight: CGFloat = 30

    init(frame: NSRect, scale: Double) {
        self.scale = scale
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = true
        minSize = NSSize(width: 240, height: 165)

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        // The bar sits above the page rather than over it, so it never hides part of the call.
        pageSlot.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - Self.barHeight)
        pageSlot.autoresizingMask = [.width, .height]
        content.addSubview(pageSlot)
        bar.frame = NSRect(x: 0, y: content.bounds.height - Self.barHeight, width: content.bounds.width, height: Self.barHeight)
        bar.autoresizingMask = [.width, .minYMargin]
        content.addSubview(bar)
        contentView = content
    }

    // Clicks reach the call's own buttons; typing (Meet's chat) needs the panel to take keys.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(_ page: NSView, tab: BrowserTab, back: @escaping () -> Void, close: @escaping () -> Void) {
        bar.rootView = AnyView(CallPiPBar(tab: tab, back: back, close: close))
        if page.superview !== pageSlot {
            page.removeFromSuperview()
            page.translatesAutoresizingMaskIntoConstraints = true
            page.autoresizingMask = [.width, .height]
            page.frame = pageSlot.bounds
            pageSlot.addSubview(page)
        }
    }

    /// Lets the page go, unless a window has already taken it back.
    func release(_ page: NSView) {
        if page.superview === pageSlot { page.removeFromSuperview() }
    }
}

/// The PiP window's top bar: drag it to move the window. The call's name, back to the tab, and close.
private struct CallPiPBar: View {
    let tab: BrowserTab
    let back: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TabIcon(tab: tab, size: 14)
                .frame(width: 14, height: 14)
            Text(tab.displayTitle)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if let call = tab.call { CallBadge(call: call) }
            Spacer(minLength: 4)
            button("pip.exit", help: "Back to the call's tab", action: back)
            button("xmark", help: "Close. The call keeps going.", action: close)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .contentShape(.rect)
        .gesture(WindowDragGesture())
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .background(.primary.opacity(0.08), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
