import XCTest

/// Compile with build-for-testing; run only on a simulator reserved for UI checks.
@MainActor final class SettingsUITests: XCTestCase {
    private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 10) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
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
        XCTAssertFalse(app.staticTexts["On This Device"].exists)
        XCTAssertFalse(app.staticTexts["Shared Agent Settings"].exists)
    }
    private func closeSettings(_ app: XCUIApplication) {
        let dismiss = app.buttons["Dismiss"]
        if dismiss.exists && dismiss.isHittable { dismiss.tap() }
        app.buttons["settings-done"].tap()
        wait(NSPredicate(format: "exists == false"), on: app.navigationBars["Settings"])
    }
    private func toggleSwitch(_ element: XCUIElement) {
        let expected = (element.value as? String) == "1" ? "0" : "1"
        // Native form accessibility can include the label in the switch frame.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(NSPredicate(format: "value == %@", expected), on: element)
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
        // Any accidental prompt PATCH would fail and reopen Settings with an error.
        let app = launch(["--settings-save-fails"])
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(toolHeader("printf 'fixture output'", in: app).waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        openSettings(app)
        let toggle = app.switches["descriptive-shell-titles"]
        XCTAssertEqual(toggle.value as? String, "0")
        toggleSwitch(toggle)
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
        toggleSwitch(toggle)
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
        toggleSwitch(local)
        XCTAssertTrue(app.buttons["settings-done"].isEnabled)
        closeSettings(app)
        openSettings(app)
        XCTAssertEqual(local.value as? String, "1")
        closeSettings(app)
    }

    func testApplyClosesImmediatelyAndSavesPromptInBackground() {
        let app = launch(["--slow-settings-save"])
        openSettings(app)
        XCTAssertFalse(app.buttons["Save System Prompt"].exists)
        let done = app.buttons["settings-done"]
        XCTAssertEqual(done.label, "Done")
        toggleSwitch(app.switches["descriptive-shell-titles"])
        XCTAssertEqual(done.label, "Done", "Local auto-save controls must not require Apply.")
        toggleSwitch(app.switches["Automatic session titles"])
        wait(NSPredicate(format: "enabled == true"), on: app.switches["Automatic session titles"])
        XCTAssertEqual(done.label, "Done", "Shared auto-save controls must not require Apply.")
        let draft = editPrompt(app)
        XCTAssertEqual(done.label, "Apply")
        done.tap()
        wait(NSPredicate(format: "exists == false"), on: app.navigationBars["Settings"], timeout: 1.5)
        XCTAssertTrue(app.buttons["Session Options"].isEnabled, "A shared save must not lock navigation.")
        XCTAssertTrue(app.buttons["New Session"].isEnabled)
        openSettings(app)
        wait(NSPredicate(format: "label == 'Done'"), on: done)
        XCTAssertEqual(app.textViews["settings-system-prompt"].value as? String, draft)
        XCTAssertEqual(done.label, "Done")
        closeSettings(app)
    }

    func testAcceptedPromptClosesEvenIfFollowUpRefreshFails() {
        let app = launch(["--settings-refresh-fails"])
        openSettings(app)
        _ = editPrompt(app)
        closeSettings(app)
        XCTAssertTrue(app.staticTexts["Fixture settings refresh failed."].waitForExistence(timeout: 5))
    }

    func testFailedBackgroundSaveReopensDraftAcrossRefreshWithoutRetryOrDuplicatePatch() {
        // Only the first PATCH fails; a duplicate or automatic retry would
        // succeed. The fake host also changes the library afterward.
        let app = launch(["--settings-save-fails", "--slow-settings-save"])
        openSettings(app)
        let draft = editPrompt(app)
        let done = app.buttons["settings-done"]
        XCTAssertEqual(done.label, "Apply")
        done.tap(withNumberOfTaps: 2, numberOfTouches: 1)
        wait(NSPredicate(format: "exists == false"), on: app.navigationBars["Settings"], timeout: 1.5)
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fixture settings save failed.")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Settings"].exists, "A failed background save must reopen Settings.")
        wait(NSPredicate(format: "label == 'Apply' AND enabled == true"), on: done)
        wait(NSPredicate(format: "value == %@", "0"), on: app.switches["Automatic session titles"])
        XCTAssertTrue(error.exists, "A background refresh must not clear the save error.")
        XCTAssertEqual(app.textViews["settings-system-prompt"].value as? String, draft,
                       "A refreshed library must not overwrite the unfocused, unsaved draft.")
        app.navigationBars["Settings"].swipeDown()
        XCTAssertTrue(app.navigationBars["Settings"].exists, "Interactive dismissal must not discard a dirty prompt.")
        XCTAssertEqual(app.textViews["settings-system-prompt"].value as? String, draft)
    }

    func testFastSaveFailureReopensAfterDismissalWithVisibleErrorAndDraft() {
        let app = launch(["--settings-save-fails"])
        openSettings(app)
        let draft = editPrompt(app)
        app.buttons["settings-done"].tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Fixture settings save failed.")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        XCTAssertEqual(app.buttons["settings-done"].label, "Apply")
        XCTAssertEqual(app.textViews["settings-system-prompt"].value as? String, draft)
    }
}
