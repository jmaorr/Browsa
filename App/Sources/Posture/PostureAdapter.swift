import SwiftUI
import OSLog

/// Every iPhone Duo-specific API call lives in this file, so if an API name differs from what's
/// written here, this is the only file to fix.
///
/// APIs used (iOS 27.1+):
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

enum PostureLog {
    static let logger = Logger(subsystem: "com.orriginal.browsa", category: "posture")
}

/// Publishes a `Posture` from the size classes alone, so the layout changes in step with the display.
struct PostureReader<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ViewBuilder var content: (Posture) -> Content

    var posture: Posture {
        #if DEBUG
        if let forced = UITestSupport.forcedUnfolded { return forced ? .unfolded : .folded }
        #endif
        // A big iPhone on its side is regular width too, but it's still a phone: it's short.
        return sizeClass == .regular && verticalSizeClass != .compact ? .unfolded : .folded
    }

    var body: some View {
        content(posture)
            .environment(\.posture, posture)
            // Swap layouts outright. Cross-fading them left two layouts on screen at once, both
            // holding the same web view while the scene moved displays, and the page could come
            // up blank with dead controls after unfolding.
            .transaction(value: posture) { t in
                t.animation = nil
                t.disablesAnimations = true
            }
            // In Console, filter on subsystem com.orriginal.browsa to line layout swaps up with
            // the web view's moves.
            .onChange(of: posture) { old, new in
                let detail = "posture \(old) -> \(new), size class: \(String(describing: sizeClass))"
                PostureLog.logger.notice("\(detail, privacy: .public)")
            }
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
