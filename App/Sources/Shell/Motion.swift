import SwiftUI
import UIKit

/// Shared motion vocabulary so every surface moves the same way.
///
/// With Reduce Motion on, every spring becomes a short cross-fade-friendly ease and slides
/// become fades, the way system apps behave. Values are computed so toggling the setting
/// applies immediately.
enum Motion {
    static var reduced: Bool { UIAccessibility.isReduceMotionEnabled }
    private static let calm = Animation.easeInOut(duration: 0.2)

    /// Default for state changes (sidebar dock/hide, sheet content changes).
    static var spring: Animation { reduced ? calm : .interpolatingSpring(mass: 1, stiffness: 320, damping: 30) }
    /// Spring that starts at the finger's speed (velocity in units per second).
    static func spring(initialVelocity v: Double) -> Animation {
        reduced ? calm : .interpolatingSpring(mass: 1, stiffness: 320, damping: 30, initialVelocity: v)
    }
    /// Tab switches and pill swaps: quicker, no overshoot.
    static var snappy: Animation { reduced ? calm : .snappy(duration: 0.28) }
    /// Small UI feedback (favourite star, chips).
    static var bouncy: Animation { reduced ? calm : .bouncy(duration: 0.35, extraBounce: 0.08) }
    /// Tab strip sliding in and out.
    static var rail: Animation { reduced ? calm : .interpolatingSpring(mass: 1, stiffness: 380, damping: 32) }
    /// Bottom bar collapsing to the small pill on scroll.
    static var collapse: Animation { reduced ? calm : .interpolatingSpring(mass: 1, stiffness: 300, damping: 26) }

    /// Page/label slide when swiping between tabs; a fade with Reduce Motion.
    static func tabPush(forward: Bool?) -> AnyTransition {
        guard let forward, !reduced else { return .opacity }
        return .push(from: forward ? .trailing : .leading)
    }
}

// MARK: - Plus button -> new-tab sheet zoom

/// IDs of the views the new-tab sheet zooms out of.
enum NewTabSource: String {
    case verticalBar = "plus.verticalBar"
    case bottomBar = "plus.bottomBar"
    case sidebar = "plus.sidebar"
    case startPage = "plus.startPage"
    case addressPill = "address.pill"
    case sidebarAddress = "address.sidebar"
}

private struct NewTabNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var newTabNamespace: Namespace.ID? {
        get { self[NewTabNamespaceKey.self] }
        set { self[NewTabNamespaceKey.self] = newValue }
    }
}

private struct ZoomSource: ViewModifier {
    @Environment(\.newTabNamespace) private var ns
    let id: NewTabSource

    func body(content: Content) -> some View {
        if let ns {
            content.matchedTransitionSource(id: id.rawValue, in: ns)
        } else {
            content
        }
    }
}

extension View {
    /// Marks this view as a place the new-tab sheet zooms out of (and back into on dismiss).
    func newTabZoomSource(_ id: NewTabSource) -> some View {
        modifier(ZoomSource(id: id))
    }
}
