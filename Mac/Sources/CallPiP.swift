import AppKit
import SwiftUI
import Observation
import BrowserCore

/// Picture in picture for calls. WebKit has no Document Picture-in-Picture (what Meet's own PiP button uses in
/// Chrome), so Browsa does it itself: when you leave a call's tab, the call's live page moves into a small floating
/// window that stays over every app and Space, scaled down so the call keeps its normal layout. Its own buttons
/// (mute, camera, leave) still work. The page fills the window; the call's name and the window's buttons float over
/// it in small glass capsules that show while the pointer is over the window. Going back to the tab, from the window's button or anywhere else, puts the
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
        // A live call (camera or microphone on) wins over a muted one, then the most recent.
        func rank(_ tab: BrowserTab) -> (Int, Date) {
            let live = tab.call.map { $0.camera || $0.microphone } ?? false
            return (live ? 1 : 0, tab.lastActive)
        }
        return library.allTabs
            .filter { $0.call != nil && !library.pipClosedFor.contains($0.id) && library.window(showing: $0) == nil }
            .max { rank($0) < rank($1) }
    }

    private func track() {
        let tab = withObservationTracking { target() } onChange: { [weak self] in
            // After the change lands, so a window showing the tab again has taken its page back first.
            Task { @MainActor in self?.track() }
        }
        update(to: tab)
    }

    private func update(to tab: BrowserTab?) {
        // Calls that ended no longer need closing for.
        let ongoing = Set(library.allTabs.filter { $0.call != nil }.map(\.id))
        if !library.pipClosedFor.isSubset(of: ongoing) {
            library.pipClosedFor.formIntersection(ongoing)
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
        if lastTabID != tab.id { panel.setMinimised(false, animated: false) }
        lastTabID = tab.id
        floating = (tab, page.zoom)
        page.zoom = Self.scale
        panel.show(page.view, tab: tab,
                   back: { [weak self] in self?.goBack(to: tab) },
                   close: { [weak self] in self?.closeAll() })
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

    /// Closing the window closes it for every call going on now, so another call doesn't pop up in its place.
    private func closeAll() {
        library.pipClosedFor.formUnion(library.allTabs.filter { $0.call != nil }.map(\.id))
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

/// The floating window: the call's page edge to edge on glass, with the call's name and the window's buttons in
/// glass capsules over its top corners. Shrinks to a round glass icon.
@MainActor
final class CallPiPPanel: NSPanel {
    private let backdrop = NSHostingView(rootView: AnyView(CallPiPBackdrop()))
    private let pageSlot = NSView()
    private let titleHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let buttonsHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let mini = NSHostingView(rootView: AnyView(EmptyView()))
    private let scale: Double
    private var callTab: BrowserTab?
    private static let miniSize: CGFloat = 52
    private static let cornerRadius: CGFloat = 16
    private static let inset: CGFloat = 8
    private static let fullMinSize = NSSize(width: 240, height: 165)
    /// Shrunk to a small glass icon, out of the way but one click from coming back.
    private(set) var isMinimised = false
    /// The full window's frame, kept while it's shrunk to the icon.
    private var fullFrame: NSRect
    /// Where to keep the window next time: its full size even while it's an icon.
    var restingFrame: NSRect { isMinimised ? fullFrame : frame }
    private var hovering = false
    private var hideTimer: Timer?
    /// Changing between the window and the icon: the name and buttons stay put and hidden meanwhile.
    private var morphing = false
    /// The widest the title capsule may be, last time it was laid out.
    private var titleWidth: CGFloat = 0

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
        minSize = Self.fullMinSize

        let content = CallPiPContentView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.cornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        backdrop.frame = content.bounds
        backdrop.autoresizingMask = [.width, .height]
        content.addSubview(backdrop)
        pageSlot.frame = content.bounds
        pageSlot.autoresizingMask = [.width, .height]
        pageSlot.wantsLayer = true
        content.addSubview(pageSlot)
        content.addSubview(titleHost)
        content.addSubview(buttonsHost)
        mini.frame = content.bounds
        mini.autoresizingMask = [.width, .height]
        mini.wantsLayer = true
        mini.alphaValue = 0
        mini.isHidden = true
        content.addSubview(mini)
        for host in [titleHost, buttonsHost] {
            host.wantsLayer = true
            host.alphaValue = 0
            host.isHidden = true
        }
        content.onResize = { [weak self] in self?.layoutChrome() }
        content.onHover = { [weak self] inside in self?.hover(inside) }
        contentView = content

        setAccessibilitySubrole(.floatingWindow)
        setAccessibilityTitle("Call")
    }

    // Clicks reach the call's own buttons; typing (Meet's chat) needs the panel to take keys.
    override var canBecomeKey: Bool { !isMinimised }
    override var canBecomeMain: Bool { false }

    func show(_ page: NSView, tab: BrowserTab, back: @escaping () -> Void, close: @escaping () -> Void) {
        callTab = tab
        titleWidth = 0
        buttonsHost.rootView = AnyView(CallPiPButtons(back: back, minimise: { [weak self] in self?.setMinimised(true) }))
        mini.rootView = AnyView(CallPiPIcon(tab: tab, expand: { [weak self] in self?.setMinimised(false) },
                                            back: back, close: close))
        if page.superview !== pageSlot {
            page.removeFromSuperview()
            page.translatesAutoresizingMaskIntoConstraints = true
            page.autoresizingMask = [.width, .height]
            page.frame = pageSlot.bounds
            pageSlot.addSubview(page)
        }
        layoutChrome()
        if !isMinimised {
            setChrome(visible: true, animated: false)
            hideChrome(after: 3)
        }
    }

    /// Lets the page go, unless a window has already taken it back.
    func release(_ page: NSView) {
        if page.superview === pageSlot { page.removeFromSuperview() }
    }

    // MARK: Chrome

    /// Puts the name capsule in the top-left corner and the buttons in the top-right, the name giving way when
    /// the window is narrow.
    private func layoutChrome() {
        guard !morphing, !isMinimised, let bounds = contentView?.bounds, let tab = callTab else { return }
        let inset = Self.inset
        let buttons = buttonsHost.fittingSize
        buttonsHost.frame = NSRect(x: bounds.maxX - inset - buttons.width, y: bounds.maxY - inset - buttons.height,
                                   width: buttons.width, height: buttons.height)
        let room = max(0, buttonsHost.frame.minX - inset * 2)
        if room != titleWidth {
            titleWidth = room
            titleHost.rootView = AnyView(CallPiPTitle(tab: tab, maxWidth: room))
        }
        let title = titleHost.fittingSize
        titleHost.frame = NSRect(x: inset, y: bounds.maxY - inset - title.height,
                                 width: min(title.width, room), height: title.height)
    }

    private func hover(_ inside: Bool) {
        hovering = inside
        if inside {
            hideTimer?.invalidate()
            if !isMinimised, !morphing { setChrome(visible: true) }
        } else {
            hideChrome(after: 1.2)
        }
    }

    /// Hides the name and buttons after a moment, unless the pointer is over the window or VoiceOver is on.
    private func hideChrome(after delay: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hovering, !NSWorkspace.shared.isVoiceOverEnabled else { return }
                self.setChrome(visible: false)
            }
        }
    }

    private func setChrome(visible: Bool, animated: Bool = true) {
        let hosts = [titleHost, buttonsHost]
        if visible { hosts.forEach { $0.isHidden = false } }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.2 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            hosts.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !visible, self.titleHost.alphaValue == 0 else { return }
                hosts.forEach { $0.isHidden = true }
            }
        }
    }

    // MARK: Minimising

    /// Shrinks to the icon in the window's bottom-right corner (where PiP windows usually sit), or grows back from
    /// wherever the icon was moved to. The call keeps running either way. The page keeps its full size throughout,
    /// faded out, so it never lays out at icon size.
    func setMinimised(_ minimised: Bool, animated: Bool = true) {
        guard minimised != isMinimised else { return }
        isMinimised = minimised
        let target: NSRect
        if minimised {
            fullFrame = frame
            target = NSRect(x: frame.maxX - Self.miniSize, y: frame.minY, width: Self.miniSize, height: Self.miniSize)
            styleMask.remove(.resizable)
            minSize = NSSize(width: Self.miniSize, height: Self.miniSize)
            hideTimer?.invalidate()
        } else {
            // Grow out from where the icon is now, kept on its screen.
            var grown = fullFrame
            grown.origin = NSPoint(x: frame.maxX - fullFrame.width, y: frame.minY)
            if let visible = screen?.visibleFrame {
                grown.origin.x = min(max(grown.minX, visible.minX), visible.maxX - grown.width)
                grown.origin.y = min(max(grown.minY, visible.minY), visible.maxY - grown.height)
            }
            target = grown
            styleMask.insert(.resizable)
            minSize = Self.fullMinSize
        }
        // The page stays at the full window's size while the window changes size around it.
        pageSlot.autoresizingMask = []
        pageSlot.frame = NSRect(origin: .zero, size: minimised ? fullFrame.size : target.size)
        let radius = minimised ? Self.miniSize / 2 : Self.cornerRadius

        guard animated, isVisible else {
            setFrame(target, display: true)
            contentView?.layer?.cornerRadius = radius
            finish(minimised)
            return
        }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduced ? 0.18 : 0.42
        let curve = reduced ? CAMediaTimingFunction(name: .easeInEaseOut)
            : CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
        morphing = true
        mini.isHidden = false
        // What's leaving fades fast, before the shape has moved far.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = minimised ? 0.12 : 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if minimised {
                pageSlot.animator().alphaValue = 0
                titleHost.animator().alphaValue = 0
                buttonsHost.animator().alphaValue = 0
            } else {
                mini.animator().alphaValue = 0
            }
        }
        // The glass changes shape with the window.
        if let layer = contentView?.layer {
            let morph = CABasicAnimation(keyPath: "cornerRadius")
            morph.fromValue = layer.cornerRadius
            morph.toValue = radius
            morph.duration = duration
            morph.timingFunction = curve
            layer.cornerRadius = radius
            layer.add(morph, forKey: "cornerRadius")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = curve
            animator().setFrame(target, display: true)
            if minimised { mini.animator().alphaValue = 1 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finish(minimised) }
        }
    }

    /// Settles the window once it's the icon or the full window again.
    private func finish(_ minimised: Bool) {
        guard minimised == isMinimised else { return }
        morphing = false
        invalidateShadow()
        if minimised {
            pageSlot.alphaValue = 0
            mini.alphaValue = 1
            mini.isHidden = false
            [titleHost, buttonsHost].forEach { $0.alphaValue = 0; $0.isHidden = true }
            return
        }
        mini.alphaValue = 0
        mini.isHidden = true
        pageSlot.frame = contentView?.bounds ?? pageSlot.frame
        pageSlot.autoresizingMask = [.width, .height]
        layoutChrome()
        // What's arriving fades in once the window has its size.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pageSlot.animator().alphaValue = 1
        }
        setChrome(visible: true)
        if !hovering { hideChrome(after: 2) }
    }
}

/// The window's own view: tells the panel when it's resized and when the pointer comes and goes.
private final class CallPiPContentView: NSView {
    var onResize: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onResize?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The glass behind everything: seen around the page as it loads, and as the window turns into the icon.
private struct CallPiPBackdrop: View {
    var body: some View {
        Color.clear
            .glassEffect(.regular, in: .rect)
            .ignoresSafeArea()
    }
}

/// The PiP window shrunk to a glass icon: the call's icon with its badge tucked on its corner, inside the circle.
/// Click to grow it back, drag to move it, right-click for more.
private struct CallPiPIcon: View {
    let tab: BrowserTab
    let expand: () -> Void
    let back: () -> Void
    let close: () -> Void

    var body: some View {
        TabIcon(tab: tab, size: 24)
            .frame(width: 24, height: 24)
            .overlay(alignment: .bottomTrailing) {
                if let call = tab.call { CallBadge(call: call, compact: true).offset(x: 6, y: 6) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .accessibilityAction { expand() }
            .accessibilityAction(named: "Show Call", expand)
            .accessibilityAction(named: "Back to the Call's Tab", back)
            .accessibilityAction(named: "Close", close)
    }
}

/// The call's icon, name and badge in a glass capsule over the top-left corner. Drag it to move the window.
private struct CallPiPTitle: View {
    let tab: BrowserTab
    let maxWidth: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            TabIcon(tab: tab, size: 14)
                .frame(width: 14, height: 14)
            Text(tab.displayTitle)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            if let call = tab.call { CallBadge(call: call) }
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 5)
        // Glass alone lets the video show through the text; a thin material under it keeps it legible.
        .background(.thinMaterial, in: .capsule)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(.capsule)
        .gesture(WindowDragGesture())
        .accessibilityElement(children: .combine)
    }
}

/// Back to the call's tab and minimise, as small glass circles over the top-right corner.
private struct CallPiPButtons: View {
    let back: () -> Void
    let minimise: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                button("pip.exit", label: "Back to the call's tab", action: back)
                button("minus", label: "Minimise to an icon. The call keeps going.", action: minimise)
            }
        }
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.thinMaterial, in: .circle)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
