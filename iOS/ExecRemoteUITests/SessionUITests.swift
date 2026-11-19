import XCTest

@MainActor final class SessionUITests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["session-fixture-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New Session"].isEnabled, "The isolated host must be connected before testing mutations.")
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
        XCTAssertGreaterThan(row.frame.minX, app.frame.minX + 10)
        XCTAssertLessThan(row.frame.maxX, app.frame.maxX - 10,
                          "Session rows must retain horizontal margins.")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
        capture("sessions-swipe", app: app)
        print("ROW AFTER SWIPE", row.frame)
        let deleteAction = app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 3))
        XCTAssertTrue(deleteAction.isHittable)
        XCTAssertGreaterThanOrEqual(deleteAction.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(deleteAction.frame.maxX, app.frame.maxX)
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

    func testFirstAndLastGroupRowsKeepNativeSwipeActions() {
        let app = launch()
        for index in [1, 6] {
            let row = app.buttons["session-fixture-\(index)"]
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
            let delete = app.buttons["Delete"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 3))
            XCTAssertTrue(delete.isEnabled)
            capture("group-edge-swipe-\(index)", app: app)
            row.swipeRight()
        }
    }

    func testSwitchingSessionsKeepsTheirIdentity() {
        let app = launch()
        for index in [1, 2, 1, 3, 2] {
            let row = app.buttons["session-fixture-\(index)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            XCTAssertTrue(app.navigationBars["Session \(index)"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "fixture-\(index) message 40")).firstMatch.waitForExistence(timeout: 5))
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["All Sessions"].waitForExistence(timeout: 5))
        }
    }

    func testDelayedSessionTitlesAndCachedReopeningKeepTheirIdentity() {
        let app = launch(["--session-title-fixture"])
        // These assertions check pending/settled navigation states, not frames
        // within the native push/pop animation.
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(app.navigationBars["Session 1"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.navigationBars["Loaded Session 1"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["All Sessions"].waitForExistence(timeout: 5))

        app.buttons["session-fixture-2"].tap()
        XCTAssertTrue(app.navigationBars["Session 2"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.navigationBars["Loaded Session 2"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.navigationBars["Loaded Session 1"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["All Sessions"].waitForExistence(timeout: 5))

        for index in [2, 1] {
            app.buttons["session-fixture-\(index)"].tap()
            XCTAssertTrue(app.navigationBars["Loaded Session \(index)"].waitForExistence(timeout: 2),
                          "A cached matching snapshot must not revert to the differing catalog title.")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["All Sessions"].waitForExistence(timeout: 5))
        }
    }

    func testSessionControlsAndNavigation() {
        let app = launch()
        XCTAssertFalse(app.toolbars["session-toolbar"].exists)
        let options = app.buttons["Session Options"]
        let newSession = app.buttons["New Session"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertLessThan(options.frame.maxX, newSession.frame.minX)
        options.tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        newSession.tap()
        XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(app.navigationBars["Session 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(options.exists, "Session controls must not occupy the conversation's composer area.")
        XCTAssertFalse(newSession.exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertTrue(newSession.isHittable)
        capture("floating-session-controls", app: app)
    }

    func testActiveSessionIndicatorsIncludeApprovalAndCancellation() {
        let app = launch(["--activity-fixture"])
        for index in 1...3 {
            let spinner = app.activityIndicators["session-active-fixture-\(index)"]
            XCTAssertTrue(spinner.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(spinner.frame.width, 12)
            XCTAssertLessThanOrEqual(spinner.frame.width, 18)
            XCTAssertLessThan(spinner.frame.midY, app.buttons["session-fixture-\(index)"].frame.midY)
            XCTAssertEqual(spinner.frame.maxX, app.buttons["session-fixture-\(index)"].frame.maxX, accuracy: 3)
        }
        for index in 4...6 {
            XCTAssertFalse(app.activityIndicators["session-active-fixture-\(index)"].exists)
        }
    }

    func testNewSessionToolsStaySelectedWhenChoosingDuringFolderRead() {
        let app = launch(["--slow-folders"])
        app.buttons["New Session"].tap()
        XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 5))
        let shell = app.switches["new-session-tool-shell"]
        if !shell.isHittable { app.swipeUp() }
        XCTAssertTrue(shell.waitForExistence(timeout: 5))
        XCTAssertEqual(shell.value as? String, "0")
        shell.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(shell.value as? String, "1")
        app.swipeDown()
        app.buttons["new-session-workspace"].tap()
        let sources = app.buttons["host-folder-/Fixture/Workspace/Sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.tap()
        XCTAssertTrue(sources.isEnabled, "Folder rows must stay interactive during reads.")
        let choose = app.navigationBars["Choose Folder"].buttons["Choose"]
        XCTAssertTrue(choose.isEnabled, "The displayed valid folder remains selectable while loading.")
        capture("folder-read-pending", app: app)
        choose.tap()
        XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 5))
        XCTAssertEqual(shell.value as? String, "1", "Returning from the picker must not reset the draft.")
        XCTAssertTrue(app.buttons["Create"].isEnabled)
        app.buttons["Create"].tap()
        XCTAssertTrue(app.navigationBars["New Session 1"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testChildrenAreSelectableInsideTheirParentCard() {
        let app = launch(["--subagent-fixture"])
        let parent = app.buttons["session-fixture-1"]
        let child = app.buttons["session-fixture-2"]
        let sibling = app.buttons["session-fixture-3"]
        XCTAssertGreaterThan(child.frame.minY, parent.frame.minY)
        XCTAssertLessThan(sibling.frame.maxY, parent.frame.maxY)
        XCTAssertLessThan(child.frame.height, parent.frame.height)
        XCTAssertEqual(child.frame.minX, parent.frame.minX, accuracy: 1)
        XCTAssertEqual(child.label, "Session 2")
        XCTAssertFalse(app.activityIndicators["session-active-fixture-2"].exists)
        capture("embedded-child-sessions", app: app)
        child.tap()
        XCTAssertTrue(app.navigationBars["Session 2"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        parent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(app.navigationBars["Session 1"].waitForExistence(timeout: 5))
    }

    func testToolGroupsShowOnlyRunningToolActivityWithoutThinkingRow() {
        let app = launch(["--tool-fixture"])
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(app.navigationBars["Tool Group"].waitForExistence(timeout: 5))
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        XCTAssertEqual(table.cells.count, 2, "The user row and the seamless tool group should be two cells.")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Running")).count, 1)
        capture("joined-running-tool-cards", app: app)
    }

    func testUserMessagesKeepAConsistentBubbleWidth() {
        let app = launch(["--bubble-fixture"])
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(app.navigationBars["Bubble Width"].waitForExistence(timeout: 5))
        let short = app.textViews.matching(NSPredicate(format: "value == %@", "Short")).firstMatch
        let longer = app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "A longer user message")).firstMatch
        XCTAssertTrue(short.waitForExistence(timeout: 5))
        XCTAssertTrue(longer.waitForExistence(timeout: 5))
        XCTAssertEqual(short.frame.width, longer.frame.width, accuracy: 1)
        XCTAssertEqual(short.frame.maxX, longer.frame.maxX, accuracy: 1)
        capture("consistent-blue-user-bubbles", app: app)
    }

    private func launchUnpaired() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--unpaired-fixture"]
        app.launch()
        return app
    }

    private func openManualPairing(_ app: XCUIApplication) -> XCUIElement {
        let scan = app.buttons["Scan Pairing QR Code"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()
        XCTAssertTrue(app.staticTexts["Camera Unavailable"].waitForExistence(timeout: 5))
        let input = app.descendants(matching: .any).matching(identifier: "manual-pairing-code").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(input.frame.width, app.frame.width * 0.75,
                             "Manual pairing input should use the native form's available width.")
        XCTAssertTrue(app.staticTexts["Enable camera access or enter the pairing code manually below."].exists)
        XCTAssertGreaterThan(app.buttons["Pair Device"].frame.maxY, app.frame.maxY - 100,
                             "Pair Device should stay at the bottom like Scan Pairing QR Code.")
        capture("manual-pairing-form", app: app)
        return input
    }

    private func pairingInvitation(expires: Double) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1, "relay": "ws://127.0.0.1:1",
            "route": String(repeating: "0", count: 64),
            "hostKey": Data(repeating: 0, count: 32).base64EncodedString(),
            "secret": String(repeating: "1", count: 64),
            "expires": expires, "localDevelopment": true
        ])
        return String(decoding: data, as: UTF8.self)
    }

    func testManualPairingAcceptsCodeAndIgnoresSurroundingWhitespace() throws {
        let app = launchUnpaired()
        let input = openManualPairing(app)
        let pair = app.buttons["Pair Device"]
        XCTAssertFalse(pair.isEnabled)
        input.tap()
        input.typeText("  \n")
        XCTAssertFalse(pair.isEnabled)
        input.typeText(try pairingInvitation(expires: Date().timeIntervalSince1970 + 600) + "\n ")
        XCTAssertTrue(pair.isEnabled)
        capture("manual-pairing-input", app: app)
        pair.tap()
        XCTAssertTrue(app.buttons["session-fixture-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New Session"].isEnabled)
    }

    func testManualPairingRejectsExpiredInvitations() throws {
        let app = launchUnpaired()
        let input = openManualPairing(app)
        input.tap()
        input.typeText(try pairingInvitation(expires: 1))
        app.buttons["Pair Device"].tap()
        XCTAssertTrue(app.staticTexts["This invitation has expired. Create a new QR code on the Mac."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Scan Pairing QR Code"].exists)
        XCTAssertFalse(app.buttons["session-fixture-1"].exists)
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
        let firstRowY = app.buttons["session-fixture-1"].frame.minY
        deleteMiddleSession(app)
        XCTAssertTrue(app.staticTexts["Fixture refresh failed."].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["session-fixture-1"].frame.minY, firstRowY, accuracy: 1,
                       "A floating notice must not shift the session list.")
        XCTAssertFalse(app.buttons["session-fixture-3"].exists)
        XCTAssertTrue(app.buttons["session-fixture-4"].exists)
        capture("deletion-accepted-refresh-failed", app: app)
        app.buttons["Dismiss"].tap()
        // The fixture keeps rejecting catalog reads, so another failure can
        // legitimately report a new notice. Dismissing must never move rows.
        XCTAssertEqual(app.buttons["session-fixture-1"].frame.minY, firstRowY, accuracy: 1)
    }
    func testDeletionFailureRestoresTheSession() {
        let app = launch(["--delete-fails"])
        deleteMiddleSession(app)
        XCTAssertTrue(app.staticTexts["Fixture deletion failed."].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["session-fixture-3"].exists)
        capture("deletion-restored", app: app)
    }
}
