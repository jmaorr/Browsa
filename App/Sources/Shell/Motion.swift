import SwiftUI
import UIKit
import BrowserCore

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
    /// Bottom bar collapsing to the small pill on scroll.
    static var collapse: Animation { reduced ? calm : .interpolatingSpring(mass: 1, stiffness: 300, damping: 26) }

    /// Page/label slide when swiping between tabs; a fade with Reduce Motion.
    static func tabPush(forward: Bool?) -> AnyTransition {
        guard let forward, !reduced else { return .opacity }
        return .push(from: forward ? .trailing : .leading)
    }
}

// MARK: - Space switch cascade

/// A tab row or card arriving because the space changed: it slides over from the side the new space
/// sits on, each one a beat after the last. Rows that appear for any other reason, like scrolling
/// into view, just appear.
private struct SpaceCascade: ViewModifier {
    let index: Int
    let distance: CGFloat
    let forward: Bool
    @State private var arrived: Bool

    init(index: Int, distance: CGFloat, spaceSwitch: BrowserState.SpaceSwitch?) {
        self.index = index
        self.distance = distance
        forward = spaceSwitch?.forward ?? true
        let justSwitched = spaceSwitch.map { Date().timeIntervalSince($0.at) < 0.3 } ?? false
        _arrived = State(initialValue: !justSwitched)
    }

    func body(content: Content) -> some View {
        content
            .offset(x: arrived || Motion.reduced ? 0 : (forward ? distance : -distance))
            .opacity(arrived ? 1 : 0)
            .onAppear {
                guard !arrived else { return }
                withAnimation(Motion.spring.delay(Double(min(index, 8)) * 0.04)) { arrived = true }
            }
    }
}

/// The outgoing list leaves toward the side away from the new space.
extension AnyTransition {
    static func spaceListChange(forward: Bool) -> AnyTransition {
        guard !Motion.reduced else { return .opacity }
        return .asymmetric(insertion: .identity,
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }
}

extension View {
    func spaceCascade(index: Int, distance: CGFloat, spaceSwitch: BrowserState.SpaceSwitch?) -> some View {
        modifier(SpaceCascade(index: index, distance: distance, spaceSwitch: spaceSwitch))
    }
}
