import AppKit
import SwiftUI
import Observation
import BrowserCore
import os

private let pipLog = Logger(subsystem: "com.orriginal.browsa", category: "callPiP")

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
        library.watchWindowVisibility()
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
            .filter { $0.call != nil && !library.pipClosedFor.contains($0.id) && library.window(visiblyShowing: $0) == nil }
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
        // A call that ended: the next call in that tab (a Meet favourite, say) starts full size again.
        if let last = lastTabID, !ongoing.contains(last), floating?.tab.id != last { lastTabID = nil }
        if floating?.tab.id == tab?.id { return }
        putBack()
        if let tab { float(tab) }
    }

    private func float(_ tab: BrowserTab) {
        guard let controller = library.existingController(for: tab), let page = controller.page else {
            pipLog.notice("Call tab has no live page to float")
            return
        }
        let panel = self.panel ?? makePanel()
        // A new call starts full size; the same call keeps the size you left it at.
        if lastTabID != tab.id { panel.setMinimised(false, animated: false) }
        // The screen it was on may be gone (a display unplugged since), which would float the call out of sight.
        if !panel.isOnScreen {
            pipLog.notice("Call window was off screen; moving it back")
            panel.moveTo(Self.defaultFrame(on: NSScreen.main))
        }
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
        // The saved place only counts if a screen connected now shows enough of it.
        if frame.width < 200 || !CallPiPPanel.showsEnough(of: frame) {
            frame = Self.defaultFrame(on: NSScreen.main)
        }
        let panel = CallPiPPanel(frame: frame, scale: Self.scale)
        self.panel = panel
        return panel
    }

    /// The bottom-right corner of a screen, where picture in picture usually sits.
    private static func defaultFrame(on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: visible.maxX - defaultSize.width - 16, y: visible.minY + 16,
                      width: defaultSize.width, height: defaultSize.height)
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
    private static let inset: CGFloat = 10
    /// The buttons' diameter and the name capsule's height.
    static let controlSize: CGFloat = 32
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

    /// The page stays fully interactive, so the call's own buttons work. Moving the window: drag the top strip
    /// while the name and buttons are showing, or Command-drag anywhere, even over the page.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isMinimised, !morphing,
           event.modifierFlags.contains(.command) || isOnTopStrip(event) {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }

    /// The band across the top that holds the name and buttons, while they're showing, apart from the buttons.
    private func isOnTopStrip(_ event: NSEvent) -> Bool {
        guard let content = contentView, !buttonsHost.isHidden, buttonsHost.alphaValue > 0 else { return false }
        let point = content.convert(event.locationInWindow, from: nil)
        guard point.y >= content.bounds.maxY - (Self.inset * 2 + Self.controlSize) else { return false }
        if let hit = content.hitTest(point), hit.isDescendant(of: buttonsHost) { return false }
        return true
    }

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

    /// Whether enough of a frame is on a screen that's connected now to see and grab it.
    static func showsEnough(of frame: NSRect) -> Bool {
        NSScreen.screens.contains {
            let shown = $0.visibleFrame.intersection(frame)
            return shown.width >= 40 && shown.height >= 40
        }
    }

    /// Whether the window (or the icon, while it's shrunk) can be seen on a screen.
    var isOnScreen: Bool { Self.showsEnough(of: frame) }

    /// Puts the full window at `full`, or the icon in that frame's bottom-right corner while it's shrunk.
    func moveTo(_ full: NSRect) {
        fullFrame = full
        let target = isMinimised
            ? NSRect(x: full.maxX - Self.miniSize, y: full.minY, width: Self.miniSize, height: Self.miniSize)
            : full
        setFrame(target, display: isVisible)
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
            returnKeyToBrowser()
        }
    }

    /// A click on the call (mute, camera) makes this panel the key window without making Browsa's window stop being
    /// main, and WebKit and SwiftUI only track the pointer in the key window. Left like that, links stop highlighting
    /// and hover controls stop showing in the browser until you click it. So once the pointer leaves the call, the
    /// browser window gets the keys back. (Typing in the call's chat means keeping the pointer over it.)
    private func returnKeyToBrowser() {
        guard isKeyWindow, NSApp.isActive, let main = NSApp.mainWindow, main !== self, main.isVisible else { return }
        main.makeKey()
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
            // The icon can't take keys, so it mustn't keep them either.
            returnKeyToBrowser()
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

/// The call's icon, name and badge in a glass capsule over the top-left corner, as tall as the buttons beside it.
private struct CallPiPTitle: View {
    let tab: BrowserTab
    let maxWidth: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            TabIcon(tab: tab, size: 16)
                .frame(width: 16, height: 16)
            Text(tab.displayTitle)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            if let call = tab.call { CallBadge(call: call) }
        }
        .padding(.leading, 10).padding(.trailing, 8)
        .frame(height: CallPiPPanel.controlSize)
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

/// Back to the call's tab and minimise, as glass circles over the top-right corner.
private struct CallPiPButtons: View {
    let back: () -> Void
    let minimise: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                button("pip.exit", label: "Back to the call's tab", action: back)
                button("minus", label: "Minimise to an icon. The call keeps going.", action: minimise)
            }
        }
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: CallPiPPanel.controlSize, height: CallPiPPanel.controlSize)
                .background(.thinMaterial, in: .circle)
                .glassEffect(.regular.interactive(), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
