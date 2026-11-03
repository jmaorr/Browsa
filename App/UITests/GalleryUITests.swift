import XCTest

/// The outer display's tab gallery. Scrolling must win over swiping and opening.
@MainActor
final class GalleryUITests: XCTestCase {
    private var app: XCUIApplication!
    private var cards: XCUIElementQuery { app.buttons.matching(identifier: "tabCard") }

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "6", "--posture", "folded"]
        app.launch()
        app.buttons["Tabs"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 3))
        sleep(1)
    }

    private func drag(_ card: XCUIElement, by dx: CGFloat, _ dy: CGFloat, velocity: XCUIGestureVelocity) {
        let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: dx, dy: dy))
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0)
    }

    func testDiagonalScrollKeepsTabsAndStaysInGallery() {
        let before = cards.count
        drag(cards.element(boundBy: 0), by: 170, -110, velocity: .fast)
        sleep(1)
        XCTAssertTrue(app.buttons["Done"].exists, "The scroll left the gallery")
        XCTAssertEqual(cards.count, before, "The scroll closed a tab")
    }

    func testLeftSwipeClosesATab() {
        let before = cards.count
        // The right-hand column, which has room to travel left on screen.
        drag(cards.element(boundBy: 1), by: -130, 0, velocity: .default)
        sleep(1)
        XCTAssertEqual(cards.count, before - 1)
    }

    func testShortAndRightSwipesCloseNothing() {
        let before = cards.count
        drag(cards.element(boundBy: 0), by: -40, 0, velocity: .slow)
        sleep(1)
        drag(cards.element(boundBy: 0), by: 130, 0, velocity: .default)
        sleep(1)
        XCTAssertEqual(cards.count, before)
    }

    /// The tabs button turns into a tick (labelled Done) while the gallery is up.
    func testTabsButtonClosesGalleryAndGutterStaysUsable() {
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Tabs"].waitForExistence(timeout: 3))
        app.buttons["Tabs"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        app.buttons["New Tab"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Done"].exists, "The gallery stayed up behind the new tab sheet")
    }
}

/// Holding the tabs button lists recent tabs, and picking one switches to it.
@MainActor
final class RecentTabsUITests: XCTestCase {
    func testHoldingTabsButtonSwitchesTab() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "3", "--posture", "folded"]
        app.launch()
        let tabs = app.buttons["Tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tab 3"].waitForExistence(timeout: 5))
        tabs.press(forDuration: 1)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Tab 1'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        XCTAssertTrue(app.staticTexts["Tab 1"].waitForExistence(timeout: 5))
    }
}

/// The inner display. Quick sidebar toggles once left the page out of place.
@MainActor
final class SidebarUITests: XCTestCase {
    func testPageReturnsToFullWidthAfterRapidToggles() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "2", "--posture", "unfolded"]
        app.launch()
        let toggle = app.buttons["Toggle Sidebar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        sleep(1)
        let before = page.frame

        for _ in 0..<4 { toggle.tap() }
        sleep(2)

        XCTAssertEqual(page.frame.minX, before.minX, accuracy: 1)
        XCTAssertEqual(page.frame.width, before.width, accuracy: 1)
    }
}
