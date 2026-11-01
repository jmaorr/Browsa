import SwiftUI

/// Shared motion vocabulary so every surface moves the same way.
enum Motion {
    /// Default for state changes (sidebar dock/hide, sheet content changes).
    static let spring = Animation.interpolatingSpring(mass: 1, stiffness: 320, damping: 30)
    /// Tab switches and pill swaps: quicker, no overshoot.
    static let snappy = Animation.snappy(duration: 0.28)
    /// Small UI feedback (favourite star, chips).
    static let bouncy = Animation.bouncy(duration: 0.35, extraBounce: 0.08)
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
