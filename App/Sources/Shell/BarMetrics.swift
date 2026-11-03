import SwiftUI

/// The sizes the layouts agree on, so the page's insets and the bars that cause them can't drift.
enum BarMetrics {
    /// How far down the top-leading corner is taken: by the status bar, or an iPad window's controls.
    static func topCornerInset(_ proxy: GeometryProxy) -> CGFloat {
        max(proxy.safeAreaInsets.top, proxy.containerCornerInsets.topLeading.height)
    }

    /// Height of the address capsule and the round buttons beside it.
    static let capsuleHeight: CGFloat = 48
    /// The capsule while the page scrolls down.
    static let compactCapsuleHeight: CGFloat = 34
    /// How far the small capsule drops into the safe area.
    static let compactCapsuleDrop: CGFloat = 20
    /// How far it can drop given the room below it, stopping short of the edge of the screen or window.
    static func compactDrop(bottomInset: CGFloat) -> CGFloat {
        min(compactCapsuleDrop, max(bottomInset - 8, 0))
    }
    /// Page space under a floating address capsule: the capsule plus the safe area below it.
    static let underCapsuleInset: CGFloat = 90
    /// The address capsule between the arrows and the edges of a big screen's bottom bar.
    static let noGutterAddressWidth: CGFloat = 440
    /// The widest a floating bottom bar gets, on anything bigger than a phone in portrait.
    static let floatingBarMaxWidth: CGFloat = 640
    /// Page space when the sidebar holds the address, so the last line clears the card's corner.
    static let dockedPageInset: CGFloat = 24
}
