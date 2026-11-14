import XCTest

@MainActor final class SessionUITests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["session-fixture-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New Chat"].isEnabled, "The isolated host must be connected before testing mutations.")
        return app
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testNavigationAndSwipeAppearance() {
        let app = launch()
        capture("sessions-rest", app: app)
        let row = app.buttons["session-fixture-3"]
        print("ROW BEFORE SWIPE", row.frame)
        XCTAssertEqual(row.frame.minX, app.frame.minX, accuracy: 2)
        XCTAssertEqual(row.frame.maxX, app.frame.maxX, accuracy: 2,
                       "Session rows must span the screen rather than an inset clipping container.")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
        capture("sessions-swipe", app: app)
        print("ROW AFTER SWIPE", row.frame)
        let deleteAction = app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 3))
        print("DELETE ACTION", deleteAction.frame)
        app.buttons["session-fixture-1"].tap()
        // The first tap may close the native swipe action without navigating.
        if !app.tables.firstMatch.waitForExistence(timeout: 2) { app.buttons["session-fixture-1"].tap() }
        XCTAssertTrue(app.tables.firstMatch.waitForExistence(timeout: 5))
        capture("transcript-bottom", app: app)
        print("TRANSCRIPT FRAME", app.tables.firstMatch.frame)
        print("NAVIGATION FRAME", app.navigationBars.firstMatch.frame)
        XCTAssertLessThan(app.tables.firstMatch.frame.minY, app.navigationBars.firstMatch.frame.minY,
                          "The transcript must extend behind the native navigation bar, not stop below it.")
        app.tables.firstMatch.swipeDown()
        capture("transcript-scrolled", app: app)
        let composer = app.descendants(matching: .any).matching(identifier: "message-composer").firstMatch
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture("transcript-keyboard", app: app)
        print("KEYBOARD FRAME", app.keyboards.firstMatch.frame)
        print("COMPOSER FRAME", composer.frame)
        XCTAssertLessThan(composer.frame.maxY, app.keyboards.firstMatch.frame.minY)
    }

    private func deleteMiddleSession(_ app: XCUIApplication) {
        let row = app.buttons["session-fixture-3"]
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
        app.buttons["Delete"].firstMatch.tap()
        // The fake host takes three seconds to respond. Check the actual row
        // removal now, not just UIKit's transient destructive-swipe animation.
        XCTAssertFalse(row.exists)
        capture("deletion-pending", app: app)
    }
    func testDeletionStaysHiddenWhenAcceptedButRefreshFails() {
        let app = launch(["--refresh-fails"])
        deleteMiddleSession(app)
        XCTAssertTrue(app.staticTexts["Fixture refresh failed."].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["session-fixture-3"].exists)
        XCTAssertTrue(app.buttons["session-fixture-4"].exists)
        capture("deletion-accepted-refresh-failed", app: app)
    }
    func testDeletionFailureRestoresTheSession() {
        let app = launch(["--delete-fails"])
        deleteMiddleSession(app)
        XCTAssertTrue(app.staticTexts["Fixture deletion failed."].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["session-fixture-3"].exists)
        capture("deletion-restored", app: app)
    }
}
