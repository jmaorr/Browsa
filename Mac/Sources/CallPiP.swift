import AppKit
import SwiftUI
import Observation
import BrowserCore

/// Picture in picture for calls. WebKit has no Document Picture-in-Picture (what Meet's own PiP button uses in
/// Chrome), so Browsa does it itself: when you leave a call's tab, the call's live page moves into a small floating
/// window that stays over every app and Space, scaled down so the call keeps its normal layout. Its own buttons
/// (mute, camera, leave) still work. Going back to the tab, from the window's button or anywhere else, puts the
/// page back. Minimising shrinks it to a small glass icon that floats in the same way; a click brings it back.
/// Closing it (from the icon's menu) leaves the capsule over the page (`CallCapsule`) as the way back.
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
    /// The last call that floated.
    private var lastTabID: UUID?

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
        // A new call starts full size; the same call keeps the size you left it at.
        if lastTabID != tab.id { panel.setMinimised(false) }
        lastTabID = tab.id
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
            UserDefaults.standard.set(NSStringFromRect(panel.restingFrame), forKey: Self.frameKey)
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

/// The floating window: a bar along the top to move it, go back or minimise it, and the call's page under it.
@MainActor
final class CallPiPPanel: NSPanel {
    private let pageSlot = NSView()
    private let bar = NSHostingView(rootView: AnyView(EmptyView()))
    private let mini = NSHostingView(rootView: AnyView(EmptyView()))
    private let scale: Double
    private static let barHeight: CGFloat = 30
    private static let miniSize: CGFloat = 52
    /// Shrunk to a small glass icon, out of the way but one click from coming back.
    private(set) var isMinimised = false
    /// The full window's frame, kept while it's shrunk to the icon.
    private var fullFrame: NSRect
    /// Where to keep the window next time: its full size even while it's an icon.
    var restingFrame: NSRect { isMinimised ? fullFrame : frame }

    init(frame: NSRect, scale: Double) {
        self.scale = scale
        fullFrame = frame
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
        mini.frame = content.bounds
        mini.autoresizingMask = [.width, .height]
        mini.isHidden = true
        content.addSubview(mini)
        contentView = content
    }

    // Clicks reach the call's own buttons; typing (Meet's chat) needs the panel to take keys.
    override var canBecomeKey: Bool { !isMinimised }
    override var canBecomeMain: Bool { false }

    func show(_ page: NSView, tab: BrowserTab, back: @escaping () -> Void, close: @escaping () -> Void) {
        bar.rootView = AnyView(CallPiPBar(tab: tab, back: back, minimise: { [weak self] in self?.setMinimised(true) }))
        mini.rootView = AnyView(CallPiPIcon(tab: tab, expand: { [weak self] in self?.setMinimised(false) },
                                            back: back, close: close))
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

    /// Shrinks to the icon in the window's bottom-right corner (where PiP windows usually sit), or grows back from
    /// wherever the icon was moved to. The call keeps running either way.
    func setMinimised(_ minimised: Bool) {
        guard minimised != isMinimised else { return }
        isMinimised = minimised
        let content = contentView
        if minimised {
            fullFrame = frame
            styleMask.remove(.resizable)
            minSize = NSSize(width: Self.miniSize, height: Self.miniSize)
            let target = NSRect(x: frame.maxX - Self.miniSize, y: frame.minY, width: Self.miniSize, height: Self.miniSize)
            pageSlot.isHidden = true
            bar.isHidden = true
            mini.isHidden = false
            content?.layer?.cornerRadius = Self.miniSize / 2
            content?.layer?.backgroundColor = NSColor.clear.cgColor
            setFrame(target, display: true, animate: true)
        } else {
            // Grow out from where the icon is now, kept on its screen.
            var target = fullFrame
            target.origin = NSPoint(x: frame.maxX - fullFrame.width, y: frame.minY)
            if let visible = screen?.visibleFrame {
                target.origin.x = min(max(target.minX, visible.minX), visible.maxX - target.width)
                target.origin.y = min(max(target.minY, visible.minY), visible.maxY - target.height)
            }
            styleMask.insert(.resizable)
            minSize = NSSize(width: 240, height: 165)
            mini.isHidden = true
            pageSlot.isHidden = false
            bar.isHidden = false
            content?.layer?.cornerRadius = 12
            content?.layer?.backgroundColor = NSColor.black.cgColor
            setFrame(target, display: true, animate: true)
        }
    }
}

/// The PiP window shrunk to a glass icon: the call's icon with its badge. Click to grow it back, drag to move it.
private struct CallPiPIcon: View {
    let tab: BrowserTab
    let expand: () -> Void
    let back: () -> Void
    let close: () -> Void

    var body: some View {
        TabIcon(tab: tab, size: 22)
            .frame(width: 22, height: 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular.interactive(), in: .circle)
            .overlay(alignment: .topTrailing) {
                if let call = tab.call { CallBadge(call: call, compact: true).offset(x: -2, y: 2) }
            }
            .contentShape(.circle)
            .onTapGesture(perform: expand)
            .gesture(WindowDragGesture())
            .help("Show the call")
            .contextMenu {
                Button("Show Call", systemImage: "pip.enter", action: expand)
                Button("Back to the Call's Tab", systemImage: "pip.exit", action: back)
                Divider()
                Button("Close", systemImage: "xmark", action: close)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Call: \(tab.displayTitle)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Show Call", expand)
            .accessibilityAction(named: "Back to the Call's Tab", back)
            .accessibilityAction(named: "Close", close)
    }
}

/// The PiP window's top bar: drag it to move the window. The call's name, back to the tab, and minimise.
private struct CallPiPBar: View {
    let tab: BrowserTab
    let back: () -> Void
    let minimise: () -> Void

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
            button("minus", help: "Minimise to an icon. The call keeps going.", action: minimise)
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
