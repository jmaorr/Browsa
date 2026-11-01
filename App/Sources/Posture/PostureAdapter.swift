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
            .duoOnHingeChange { hingeOpen = $0 }
    }
}

extension View {
    /// Calls `action` with true (open), false (closed) or nil (not a Duo) when the hinge moves.
    func duoOnHingeChange(_ action: @escaping (Bool?) -> Void) -> some View {
        #if NO_DUO_SDK
        self
        #else
        onHingeChange { _, new in
            guard let hinge = new.hinge else { action(nil); return }
            switch hinge.status {
            case .closed: action(false)
            case .partiallyOpen, .fullyOpen: action(true)
            @unknown default: action(nil)
            }
        }
        #endif
    }
}

// MARK: - Vertical bar ("gutter toolbar") helpers

//
// NO_DUO_SDK: CI's Xcode doesn't have the iOS 27.1 SDK yet, so it builds the app with this flag and
// these no-op stand-ins. Everything else in the app still gets compiled and type-checked.

extension View {
    /// Unfolded layout: keep the sidebar toggle + plus in the system vertical bar, never in overflow.
    func duoVerticalBarPrefersOurItems() -> some View {
        #if NO_DUO_SDK
        self
        #else
        toolbarVerticalCompressionBehavior(.prefersToolbarItems)
        #endif
    }

    /// Folded layout: we draw our own Arc-style bottom bar, so switch the system vertical bar off.
    func duoDisableVerticalBar() -> some View {
        #if NO_DUO_SDK
        self
        #else
        toolbarVerticalBehavior(.disabled)
        #endif
    }
}

extension ToolbarContent {
    /// Pin an item to the vertical bar and keep it out of the overflow menu.
    func duoPinnedToVerticalBar() -> some ToolbarContent {
        #if NO_DUO_SDK
        self
        #else
        self.axisBehavior(.verticalPreferred).visibilityPriority(.high)
        #endif
    }
}

#if NO_DUO_SDK
private struct VerticalEdgeStandIn: EnvironmentKey { static let defaultValue: HorizontalEdge? = nil }
#endif

extension EnvironmentValues {
    /// Which edge the system put its vertical bar on (nil when there isn't one).
    var duoToolbarVerticalEdge: HorizontalEdge? {
        #if NO_DUO_SDK
        self[VerticalEdgeStandIn.self]
        #else
        toolbarVerticalEdge
        #endif
    }
}
