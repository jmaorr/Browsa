import SwiftUI
import AppKit

/// The window's close, minimise and zoom buttons, as part of the sidebar's top row, like Arc.
///
/// They're AppKit's own buttons (`NSWindow.standardWindowButton(_:for:)`), so they look, hover and
/// act like the real ones, but they live in the sidebar: they slide and fade with it, docked or
/// peeking. In full screen the sidebar has none: the title bar's own drop down with the menu bar,
/// as in every app.
struct WindowButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowButtonsView { WindowButtonsView() }

    func updateNSView(_ view: WindowButtonsView, context: Context) {}

    /// The row's width for the buttons: AppKit's spacing, plus the gap after them.
    static let width: CGFloat = 68
}

final class WindowButtonsView: NSView {
    private static let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
    private let buttons: [NSButton]
    private var hovering = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        buttons = Self.kinds.compactMap { NSWindow.standardWindowButton($0, for: style) }
        super.init(frame: .zero)
        buttons.forEach(addSubview)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The three buttons with the title bar's spacing (6 pt between them), centred vertically.
    /// Measured from the buttons themselves: the title bar's own are hidden, so their frames can't
    /// be trusted.
    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for button in buttons {
            var size = button.frame.size
            if size.width < 1 || size.height < 1 { size = button.fittingSize }
            if size.width < 1 || size.height < 1 { size = NSSize(width: 14, height: 16) }
            button.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + 6
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
        needsLayout = true
        redraw()
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
