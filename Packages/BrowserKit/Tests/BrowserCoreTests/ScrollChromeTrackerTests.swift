import CoreGraphics
import Testing
@testable import BrowserCore

@Suite struct ScrollChromeTrackerTests {
    private func scroll(_ t: inout ScrollChromeTracker, through ys: [CGFloat]) {
        for y in ys { t.update(offsetY: y, contentHeight: 5000, viewportHeight: 800) }
    }

    @Test func collapsesAfterThresholdDown() {
        var t = ScrollChromeTracker()
        scroll(&t, through: [100, 110, 120])
        #expect(!t.isCompact)          // 20pt: under the 24pt threshold
        scroll(&t, through: [130])
        #expect(t.isCompact)
    }

    @Test func jitterDoesNotToggle() {
        var t = ScrollChromeTracker()
        scroll(&t, through: [100, 140, 180])
        #expect(t.isCompact)
        scroll(&t, through: [179.8, 179.6, 180, 170, 175, 165])   // small back-and-forth < 24pt up
        #expect(t.isCompact)
    }

    @Test func expandsAfterThresholdUp() {
        var t = ScrollChromeTracker()
        scroll(&t, through: [100, 200, 300])
        #expect(t.isCompact)
        scroll(&t, through: [290, 280, 270])
        #expect(t.isCompact == false)
    }

    @Test func topAndBottomAlwaysExpand() {
        var t = ScrollChromeTracker()
        scroll(&t, through: [100, 200, 300])
        #expect(t.isCompact)
        scroll(&t, through: [2])
        #expect(!t.isCompact)
        scroll(&t, through: [1000, 2000, 3000])
        #expect(t.isCompact)
        scroll(&t, through: [4200])     // 4200 + 800 = content height: bottom
        #expect(!t.isCompact)
    }

    @Test func shortPagesNeverCollapse() {
        var t = ScrollChromeTracker()
        for y in stride(from: CGFloat(0), through: 10, by: 1) {
            t.update(offsetY: y, contentHeight: 810, viewportHeight: 800)
        }
        #expect(!t.isCompact)
    }

    @Test func expandResetsSoNextScrollNeedsFullThreshold() {
        var t = ScrollChromeTracker()
        scroll(&t, through: [100, 200, 300])
        t.expand()
        scroll(&t, through: [310, 320])
        #expect(!t.isCompact)
        scroll(&t, through: [330, 340])
        #expect(t.isCompact)
    }
}
