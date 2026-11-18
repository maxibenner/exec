import XCTest

/// Compile with build-for-testing; run only on a simulator reserved for UI checks.
@MainActor final class SettingsUITests: XCTestCase {
    private func wait(_ predicate: NSPredicate, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--settings-fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["session-fixture-1"].waitForExistence(timeout: 10))
        wait(NSPredicate(format: "enabled == true"), on: app.buttons["Session Options"])
        if !arguments.contains("--settings-offline") {
            wait(NSPredicate(format: "enabled == true"), on: app.buttons["New Session"])
        }
        return app
    }
    private func openSettings(_ app: XCUIApplication) {
        app.buttons["Session Options"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }
    private func closeSettings(_ app: XCUIApplication) {
        app.buttons["Done"].tap()
        wait(NSPredicate(format: "exists == false"), on: app.navigationBars["Settings"])
    }
    private func toolHeader(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
    private func editPrompt(_ app: XCUIApplication) -> String {
        let editor = app.textViews["settings-system-prompt"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("\nLocally edited fixture instructions")
        return editor.value as? String ?? ""
    }

    func testLocalShellTitlesReprojectCachedToolsAndKeepDetails() {
        // Any accidental prompt PATCH would fail, preventing Done from closing.
        let app = launch(["--settings-save-fails"])
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(toolHeader("printf 'fixture output'", in: app).waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        openSettings(app)
        let toggle = app.switches["descriptive-shell-titles"]
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap()
        closeSettings(app)
        openSettings(app)
        XCTAssertEqual(toggle.value as? String, "1", "The local preference must survive reopening Settings.")
        closeSettings(app)
        app.buttons["session-fixture-1"].tap()
        let described = toolHeader("Print fixture output", in: app)
        XCTAssertTrue(described.waitForExistence(timeout: 5))
        XCTAssertTrue(toolHeader("pwd", in: app).exists, "Blank descriptions must fall back to commands.")
        described.tap()
        XCTAssertTrue(app.staticTexts["printf 'fixture output'"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Exit code: 0\nfixture output"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        openSettings(app)
        toggle.tap()
        closeSettings(app)
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(toolHeader("printf 'fixture output'", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(toolHeader("Print fixture output", in: app).exists)
    }

    func testOfflineSettingsKeepLocalToggleAndUnchangedDoneAvailable() {
        let app = launch(["--settings-offline"])
        openSettings(app)
        let local = app.switches["descriptive-shell-titles"]
        XCTAssertTrue(local.isEnabled)
        XCTAssertFalse(app.switches["Automatic session titles"].isEnabled)
        XCTAssertFalse(app.textViews["settings-system-prompt"].isEnabled)
        local.tap()
        XCTAssertTrue(app.buttons["Done"].isEnabled)
        closeSettings(app)
        openSettings(app)
        XCTAssertEqual(local.value as? String, "1")
        closeSettings(app)
    }

    func testDoneWaitsForAcknowledgementAndSavesPrompt() {
        let app = launch(["--slow-settings-save"])
        openSettings(app)
        XCTAssertFalse(app.buttons["Save System Prompt"].exists)
        let draft = editPrompt(app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].exists, "Do not dismiss an unacknowledged save.")
        XCTAssertFalse(app.buttons["Done"].isEnabled)
        wait(NSPredicate(format: "exists == false"), on: app.navigationBars["Settings"])
        openSettings(app)
        XCTAssertEqual(app.textViews["settings-system-prompt"].value as? String, draft)
        closeSettings(app)
    }

    func testAcceptedPromptClosesEvenIfFollowUpRefreshFails() {
        let app = launch(["--settings-refresh-fails"])
        openSettings(app)
        _ = editPrompt(app)
        closeSettings(app)
        XCTAssertTrue(app.staticTexts["Fixture settings refresh failed."].waitForExistence(timeout: 5))
    }

    func testFailedPromptSaveKeepsDraftAcrossBackgroundRefreshWithoutRetry() {
        // Only the first PATCH fails; an automatic retry would succeed and
        // dismiss the sheet. The fake host also changes the library afterward.
        let app = launch(["--settings-save-fails", "--slow-settings-save"])
        openSettings(app)
        let draft = editPrompt(app)
        app.buttons["Done"].tap()
        wait(NSPredicate(format: "enabled == true"), on: app.buttons["Done"])
        wait(NSPredicate(format: "value == %@", "0"), on: app.switches["Automatic session titles"])
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        XCTAssertEqual(app.textViews["settings-system-prompt"].value as? String, draft,
                       "A refreshed library must not overwrite the unfocused, unsaved draft.")
        app.navigationBars["Settings"].swipeDown()
        XCTAssertTrue(app.navigationBars["Settings"].exists, "Interactive dismissal must not discard a dirty prompt.")
        XCTAssertEqual(app.textViews["settings-system-prompt"].value as? String, draft)
    }
}
