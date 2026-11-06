import SwiftUI
import AppKit

/// Two-finger horizontal swipes over the sidebar switch spaces, like Arc.
///
/// A local scroll-wheel monitor, so the sidebar's own vertical scrolling is untouched. The probe view
/// marks where the sidebar is; swipes elsewhere (over the page) are left to the page.
struct SpaceSwipeArea: NSViewRepresentable {
    /// -1 for the previous space, +1 for the next.
    let onSwipe: @MainActor (Int) -> Void

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onSwipe = onSwipe
        return v
    }

    func updateNSView(_ v: Probe, context: Context) { v.onSwipe = onSwipe }

    final class Probe: NSView {
        var onSwipe: (@MainActor (Int) -> Void)?
        private var monitor: Any?
        private var dx: CGFloat = 0
        private var dy: CGFloat = 0
        private var fired = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) ?? false } ? nil : event
            }
        }

        /// Returns true when the event was used for a space switch.
        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === window, event.hasPreciseScrollingDeltas else { return false }
            let p = convert(event.locationInWindow, from: nil)
            guard bounds.contains(p) else { return false }
            if event.phase == .began { dx = 0; dy = 0; fired = false }
            dx += event.scrollingDeltaX
            dy += event.scrollingDeltaY
            if event.phase == .ended || event.phase == .cancelled { dx = 0; dy = 0; fired = false; return false }
            guard !fired, abs(dx) > 50, abs(dx) > abs(dy) * 2 else { return abs(dx) > abs(dy) * 2 && abs(dx) > 8 }
            fired = true
            // Fingers moving left bring in the space to the right.
            onSwipe?(dx < 0 ? 1 : -1)
            return true
        }
    }
}
