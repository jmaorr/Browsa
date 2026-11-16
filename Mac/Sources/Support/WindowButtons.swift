import SwiftUI
import AppKit

/// The window's close, minimise and zoom buttons, as part of the sidebar's top row, like Arc.
///
/// They're AppKit's own buttons (`NSWindow.standardWindowButton(_:for:)`), so they look, hover and
/// act like the real ones, but they live in the sidebar: they slide and fade with it, docked or
/// peeking, in a window or in full screen. The window's title bar buttons stay hidden for good.
struct WindowButtons: NSViewRepresentable {
    /// The window is in full screen, where macOS greys out minimise.
    var isFullScreen = false

    func makeNSView(context: Context) -> WindowButtonsView { WindowButtonsView() }

    func updateNSView(_ view: WindowButtonsView, context: Context) {
        view.isFullScreen = isFullScreen
    }

    /// The row's width for the buttons: AppKit's spacing, plus the gap after them.
    static let width: CGFloat = 68
}

final class WindowButtonsView: NSView {
    private static let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private let buttons: [NSButton]
    private var hovering = false
    private var observers: [NSObjectProtocol] = []

    var isFullScreen = false {
        didSet { if isFullScreen != oldValue { updateEnabled() } }
    }

    init() {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        buttons = Self.kinds.compactMap { NSWindow.standardWindowButton($0, for: style) }
        super.init(frame: .zero)
        buttons.forEach(addSubview)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The three buttons with the spacing the title bar uses on this version of macOS, centred
    /// vertically, starting where the title bar would put the close button.
    override func layout() {
        super.layout()
        let native = window.map { w in Self.kinds.compactMap { w.standardWindowButton($0)?.frame } } ?? []
        let step = native.count == 3 ? native[1].minX - native[0].minX : 20
        // The title bar's close button sits this far in from the window's edge; the sidebar row has
        // 8 pt of padding of its own.
        let lead = native.first.map { max(0, $0.minX - 8) } ?? 0
        for (i, button) in buttons.enumerated() {
            let size = button.frame.size == .zero ? button.intrinsicContentSize : button.frame.size
            button.frame = NSRect(x: lead + CGFloat(i) * step, y: ((bounds.height - size.height) / 2).rounded(),
                                  width: size.width, height: size.height)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        // Left with the pointer over it (the sidebar slid away): no exit event comes.
        hovering = false
        guard let window else { return }
        // The buttons go grey when the window isn't key, and back when it is.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.redraw() }
            })
        }
        updateEnabled()
        needsLayout = true
        redraw()
    }

    private func updateEnabled() {
        if buttons.count == 3 { buttons[1].isEnabled = !isFullScreen }
    }

    // MARK: Hover

    // Hovering any of the three shows the symbols on all of them, as in the title bar. AppKit's
    // buttons ask their superview whether the pointer is in their group.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let group = buttons.reduce(NSRect.null) { $0.union($1.frame) }
        guard !group.isNull else { return }
        addTrackingArea(NSTrackingArea(rect: group, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; redraw() }
    override func mouseExited(with event: NSEvent) { hovering = false; redraw() }

    @objc func _mouseInGroup(_ button: NSButton) -> Bool { hovering }

    private func redraw() { buttons.forEach { $0.needsDisplay = true } }
}
