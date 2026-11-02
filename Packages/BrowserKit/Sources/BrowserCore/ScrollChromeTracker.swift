import Foundation
import CoreGraphics

/// Decides when the browser chrome (bottom bar) should collapse to a small pill, the way Safari
/// does: from scroll *direction* with hysteresis, never from per-frame layout.
///
/// Feed it the web view's scroll offset as it changes. It flips one Bool:
/// - scrolling down more than `threshold` points since the last direction change -> compact
/// - scrolling up more than `threshold` points -> expanded
/// - at (or bouncing past) the top or the bottom of the page -> expanded
/// Small jitters (a finger resting, sub-point momentum) never toggle it.
public struct ScrollChromeTracker: Sendable {
    public var threshold: CGFloat
    public private(set) var isCompact = false

    private var anchor: CGFloat = 0
    private var lastY: CGFloat?
    private var lastDirection = 0

    public init(threshold: CGFloat = 24) {
        self.threshold = threshold
    }

    /// - Returns: true if `isCompact` changed.
    @discardableResult
    public mutating func update(offsetY y: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat,
                                topInset: CGFloat = 0) -> Bool {
        let before = isCompact
        defer { lastY = y }

        let atTop = y <= -topInset + 4
        let atBottom = contentHeight > viewportHeight && y + viewportHeight >= contentHeight - 4
        // Pages too short to scroll never collapse the chrome.
        if atTop || atBottom || contentHeight <= viewportHeight + threshold {
            isCompact = false
            anchor = y
            lastDirection = 0
            return before != isCompact
        }

        guard let last = lastY else { anchor = y; return false }
        let delta = y - last
        guard abs(delta) >= 0.5 else { return false }
        let direction = delta > 0 ? 1 : -1
        if direction != lastDirection {
            anchor = last
            lastDirection = direction
        }
        if direction > 0, !isCompact, y - anchor > threshold { isCompact = true }
        if direction < 0, isCompact, anchor - y > threshold { isCompact = false }
        return before != isCompact
    }

    /// Call when the page changes or the user taps the pill.
    public mutating func expand() {
        isCompact = false
        lastDirection = 0
        if let lastY { anchor = lastY }
    }
}
