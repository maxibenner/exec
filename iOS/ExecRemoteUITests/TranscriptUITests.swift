import XCTest

/// All launches use the fake in-memory transport. Attachments are XCTest
/// artifacts, not a claim of physical-device or live-service visual validation.
@MainActor final class TranscriptUITests: XCTestCase {
    private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 12) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--transcript-fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["session-fixture-1"].waitForExistence(timeout: 10))
        wait(NSPredicate(format: "enabled == true"), on: app.buttons["New Session"])
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(app.tables["native-transcript"].waitForExistence(timeout: 5))
        return app
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func header(_ name: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "printf '\(name)'")).firstMatch
    }

    func testJoinedToolsUseOneCellWithIndependentDisclosuresAndSpinner() {
        let app = launch(["--transcript-tools"])
        let table = app.tables["native-transcript"]
        let first = header("first", app: app), second = header("second", app: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(table.cells.count, 2, "The user row and the entire adjacent tool group are two cells, not four self-sized hosts.")
        XCTAssertEqual(first.value as? String, "Collapsed")
        XCTAssertEqual(second.value as? String, "Collapsed")
        XCTAssertTrue(header("active", app: app).label.contains("Running"))
        XCTAssertEqual(first.frame.maxY, second.frame.minY, accuracy: 0.34)
        first.tap()
        wait(NSPredicate(format: "value == %@", "Expanded"), on: first)
        XCTAssertEqual(second.value as? String, "Collapsed")
        XCTAssertTrue(app.staticTexts["Isolated first output"].exists)
        second.tap()
        wait(NSPredicate(format: "value == %@", "Expanded"), on: second)
        XCTAssertEqual(first.value as? String, "Expanded")
        first.tap()
        wait(NSPredicate(format: "value == %@", "Collapsed"), on: first)
        XCTAssertEqual(second.value as? String, "Expanded")
        XCTAssertTrue(header("active", app: app).label.contains("Running"))
        XCTAssertLessThan(table.frame.minY, app.navigationBars.firstMatch.frame.minY,
                          "Native material chrome must not remove transcript underlap.")
        capture("one-host-joined-tools", app: app)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["session-fixture-2"].tap()
        XCTAssertTrue(header("first", app: app).waitForExistence(timeout: 5))
        XCTAssertEqual(header("first", app: app).value as? String, "Collapsed")
        XCTAssertEqual(header("second", app: app).value as? String, "Collapsed")
        header("first", app: app).tap()
        wait(NSPredicate(format: "value == %@", "Expanded"), on: header("first", app: app))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(header("second", app: app).waitForExistence(timeout: 5))
        XCTAssertEqual(header("first", app: app).value as? String, "Collapsed")
        XCTAssertEqual(header("second", app: app).value as? String, "Expanded")
    }

    func testSendReservesResponseSpaceAndManualReadingSurvivesStreaming() {
        let app = launch()
        let table = app.tables["native-transcript"]
        let composer = app.descendants(matching: .any).matching(identifier: "message-composer").firstMatch
        composer.tap()
        composer.typeText("A smooth synthetic turn")
        app.buttons["Send"].tap()
        let sent = table.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript-message-local-")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 5))
        let expectedTop = app.navigationBars.firstMatch.frame.maxY + 8
        wait(NSPredicate { _, _ in abs(sent.textViews.firstMatch.frame.minY - expectedTop) < 4 }, on: sent)
        let pinnedY = sent.frame.minY
        let answer = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Response paragraph 1.")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        wait(NSPredicate(format: "value CONTAINS %@", "Response paragraph 5."), on: answer)
        XCTAssertEqual(sent.frame.minY, pinnedY, accuracy: 2, "Response growth must consume blank space, not push the sent turn upward per layout.")
        XCTAssertLessThan(composer.frame.maxY, app.keyboards.firstMatch.frame.minY)
        capture("sent-turn-top-reservation", app: app)

        XCTAssertTrue(app.buttons["Stop"].exists, "The fixture must still be streaming when manual reading begins.")
        table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.1, thenDragTo: table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
                   withVelocity: .slow, thenHoldForDuration: 0.4)
        let reading = table.cells["transcript-message-history-24"]
        XCTAssertTrue(reading.waitForExistence(timeout: 5))
        let readingY = reading.frame.minY
        wait(NSPredicate(format: "exists == false"), on: app.buttons["Stop"], timeout: 25)
        XCTAssertEqual(reading.frame.minY, readingY, accuracy: 3, "Finishing a response must not re-enable following while reading history.")
        capture("manual-reading-after-stream", app: app)

        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["session-fixture-2"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "fixture-2 reading marker 24")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["session-fixture-1"].tap()
        let restored = app.tables["native-transcript"].cells["transcript-message-history-24"]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertEqual(restored.frame.minY, readingY, accuracy: 3,
                       "Reopening must preserve the reader's position, not scroll to the response's end.")
    }

    func testCachedReadingPositionRestoresAcrossSessions() throws {
        let app = launch()
        let table = app.tables["native-transcript"]
        table.swipeDown(velocity: .slow)
        let top = app.navigationBars.firstMatch.frame.maxY
        let anchor = try XCTUnwrap(table.cells.allElementsBoundByIndex.first { cell in
            let frame = cell.frame
            return cell.identifier.hasPrefix("transcript-message-history-")
                && frame.minY > top + 12 && frame.maxY < table.frame.maxY - 100
        })
        let identifier = anchor.identifier, y = anchor.frame.minY
        capture("cached-reading-before-navigation", app: app)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["session-fixture-2"].tap()
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "fixture-2 reading marker 24")).firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["session-fixture-1"].tap()
        let restored = app.tables["native-transcript"].cells[identifier]
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        wait(NSPredicate { _, _ in restored.isHittable }, on: restored)
        XCTAssertEqual(restored.frame.minY, y, accuracy: 3)
        capture("cached-reading-after-navigation", app: app)
    }

    func testCachedToolTitlesReprojectWithoutChangingExpandedDetails() {
        let app = launch(["--transcript-tools"])
        XCTAssertTrue(header("first", app: app).waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Session Options"].tap(); app.buttons["Settings"].tap()
        let toggle = app.switches["descriptive-shell-titles"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        wait(NSPredicate(format: "value == %@", "1"), on: toggle)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["session-fixture-1"].waitForExistence(timeout: 5))
        app.buttons["session-fixture-1"].tap()
        let described = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Print first")).firstMatch
        XCTAssertTrue(described.waitForExistence(timeout: 5))
        described.tap()
        XCTAssertTrue(app.staticTexts["printf 'first'"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Isolated first output"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Print active")).firstMatch.label.contains("Running"))
    }

    func testReducedMotionSendStillReservesResponseSpace() {
        let app = launch(["--transcript-reduce-motion"])
        let table = app.tables["native-transcript"]
        let composer = app.descendants(matching: .any).matching(identifier: "message-composer").firstMatch
        composer.tap(); composer.typeText("Reduced motion question")
        app.buttons["Send"].tap()
        let sent = table.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript-message-local-")).firstMatch
        let expectedTop = app.navigationBars.firstMatch.frame.maxY + 8
        wait(NSPredicate { _, _ in abs(sent.textViews.firstMatch.frame.minY - expectedTop) < 4 }, on: sent)
    }

    func testStreamingFollowCoalescesAndOnlyResumesAfterScrollingDown() {
        let app = launch(["--transcript-follow"])
        let table = app.tables["native-transcript"]
        let answer = table.cells["transcript-message-streaming-answer"]
        let text = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Response paragraph 1.")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        let bottom = answer.frame.maxY
        wait(NSPredicate(format: "value CONTAINS %@", "Response paragraph 25."), on: text)
        wait(NSPredicate { _, _ in abs(answer.frame.maxY - bottom) < 3 }, on: answer)
        table.swipeDown()
        let readingY = answer.frame.minY
        wait(NSPredicate(format: "value CONTAINS %@", "Response paragraph 40."), on: text)
        XCTAssertEqual(answer.frame.minY, readingY, accuracy: 3)
        // The response keeps growing during each gesture. Scroll until the
        // gesture actually reaches the bottom instead of assuming five swipes.
        for _ in 0..<12 {
            if answer.frame.maxY <= bottom + 3 { break }
            table.swipeUp(velocity: .fast)
        }
        XCTAssertLessThanOrEqual(answer.frame.maxY, bottom + 3, "An explicit gesture must reach the bottom before following can resume.")
        wait(NSPredicate { _, _ in abs(answer.frame.maxY - bottom) < 3 }, on: answer)
        wait(NSPredicate(format: "value CONTAINS %@", "Response paragraph 60."), on: text, timeout: 20)
        wait(NSPredicate { _, _ in abs(answer.frame.maxY - bottom) < 3 }, on: answer)
        capture("stream-follow-after-explicit-bottom-scroll", app: app)
    }

    func testPagingPreservesTheVisibleMessageAndPixelOffset() {
        let app = launch(["--transcript-paging"])
        let table = app.tables["native-transcript"]
        let anchor = table.cells["transcript-message-history-13"]
        let navigationBottom = app.navigationBars.firstMatch.frame.maxY
        for _ in 0..<6 {
            if anchor.exists, anchor.frame.minY > navigationBottom - 100, anchor.frame.minY < navigationBottom + 100 { break }
            table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.1, thenDragTo: table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)),
                       withVelocity: .slow, thenHoldForDuration: 0.4)
        }
        XCTAssertTrue(anchor.exists)
        let y = anchor.frame.minY
        XCTAssertLessThan(y, navigationBottom + 120, "The paging gesture must reach the loaded history boundary.")
        XCTAssertTrue(table.cells["transcript-message-history-12"].waitForExistence(timeout: 10))
        XCTAssertEqual(anchor.frame.minY, y, accuracy: 3)
        capture("paging-preserved-reading-anchor", app: app)
    }
}
