import SwiftUI

/// Every iPhone Duo-specific API call lives in this file, so if an API name differs from what's
/// written here, this is the only file to fix.
///
/// APIs used (iOS 27.1+):
///   - View.onHingeChange { old, new in new.hinge?.status }    -> .closed / .partiallyOpen / .fullyOpen
///   - EnvironmentValues.toolbarVerticalEdge                    -> HorizontalEdge? (nil = no vertical bar)
///   - View.toolbarVerticalBehavior(_:)                         -> .automatic / .disabled
///   - View.toolbarVerticalCompressionBehavior(_:)              -> .prefersToolbarItems
///   - ToolbarContent.axisBehavior(_:)                          -> .verticalPreferred
///   - ToolbarContent.visibilityPriority(_:)                    -> .high

enum Posture: Equatable {
    /// Outer 5.4" display, or any compact-width iPhone: phone layout with bottom bar.
    case folded
    /// Inner 7.6" display (fully or partially open), or any regular-width device: sidebar layout.
    case unfolded
}

private struct PostureKey: EnvironmentKey {
    static let defaultValue: Posture = .folded
}

extension EnvironmentValues {
    var posture: Posture {
        get { self[PostureKey.self] }
        set { self[PostureKey.self] = newValue }
    }
}

/// Reads the hinge (when there is one) and the size class, and publishes a `Posture`.
struct PostureReader<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var hingeOpen: Bool?   // nil = not a Duo, fall back to size class
    @ViewBuilder var content: (Posture) -> Content

    var posture: Posture {
        if let hingeOpen { return hingeOpen ? .unfolded : .folded }
        return sizeClass == .regular ? .unfolded : .folded
    }

    var body: some View {
        content(posture)
            .environment(\.posture, posture)
            .animation(.smooth(duration: 0.35), value: posture)
            .onHingeChange { _, new in
                guard let hinge = new.hinge else { hingeOpen = nil; return }
                switch hinge.status {
                case .closed: hingeOpen = false
                case .partiallyOpen, .fullyOpen: hingeOpen = true
                @unknown default: hingeOpen = nil
                }
            }
    }
}

// MARK: - Vertical bar ("gutter toolbar") helpers

extension View {
    /// Unfolded layout: keep the sidebar toggle + plus in the system vertical bar, never in overflow.
    func duoVerticalBarPrefersOurItems() -> some View {
        toolbarVerticalCompressionBehavior(.prefersToolbarItems)
    }

    /// Folded layout: we draw our own Arc-style bottom bar, so switch the system vertical bar off.
    func duoDisableVerticalBar() -> some View {
        toolbarVerticalBehavior(.disabled)
    }
}

extension ToolbarContent {
    /// Pin an item to the vertical bar and keep it out of the overflow menu.
    func duoPinnedToVerticalBar() -> some ToolbarContent {
        self.axisBehavior(.verticalPreferred).visibilityPriority(.high)
    }
}

/// Which edge the system put its vertical bar on (nil when there isn't one).
struct VerticalBarEdgeReader<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    @ViewBuilder var content: (HorizontalEdge?) -> Content
    var body: some View { content(edge) }
}
