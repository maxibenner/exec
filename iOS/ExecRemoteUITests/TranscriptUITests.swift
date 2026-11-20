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

    func testMarkdownUsesOneMultilineCodeSurfaceAndFullSizeScrollableTable() {
        let app = launch(["--transcript-markdown"])
        print("Markdown accessibility hierarchy before horizontal scrolling:\n\(app.debugDescription)")
        let transcript = app.tables["native-transcript"]
        // UIKit flattens the non-element block/scroll wrappers in accessibility.
        // Count the selectable region, not TextKit's individual line children.
        let codeRegions = app.textViews.matching(identifier: "markdown-code-text")
        XCTAssertTrue(codeRegions.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(codeRegions.count, 1, "One fence must use one continuous selectable multiline region.")
        let code = codeRegions.firstMatch
        XCTAssertTrue((code.value as? String)?.contains("let first = 1\nlet second = 2\nprint(") == true)
        XCTAssertGreaterThan(code.frame.height, 35)
        XCTAssertEqual(transcript.cells.count, 2, "Block views stay inside one virtualized assistant message cell.")
        let user = transcript.cells["transcript-message-markdown-user"].textViews.firstMatch
        XCTAssertEqual(user.value as? String, "**Literal user text** and `inline code`")

        let first = app.textViews["markdown-table-cell-1-0"]
        let last = app.textViews["markdown-table-cell-0-4"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(last.exists, "The offscreen column must remain an accessible text region.")
        XCTAssertTrue(first.isHittable)
        // Offscreen UITextView frames can fall back to the message cell's frame;
        // TextKit's text children retain their actual glyph bounds after clipping.
        let firstText = first.textViews.firstMatch, lastText = last.textViews.firstMatch
        let firstFrame = firstText.frame, lastFrame = lastText.frame, userY = user.frame.minY
        let top = app.textViews["markdown-table-cell-0-0"].textViews.firstMatch
        let bottom = app.textViews["markdown-table-cell-2-0"].textViews.firstMatch
        let y = top.frame.minY, tableTextHeight = bottom.frame.maxY - y
        let bodyFrame = transcript.cells["transcript-message-markdown-answer"].textViews
            .matching(NSPredicate(format: "value == %@", "Between native blocks.")).firstMatch.frame
        XCTAssertGreaterThan(lastFrame.minX, bodyFrame.maxX, "The fixture must require horizontal scrolling.")
        // Use the visible row's screen position; the wide text frames extend
        // offscreen and the horizontal UIScrollView is not an AX scroll element.
        let origin = transcript.coordinate(withNormalizedOffset: .zero)
        let rowY = firstFrame.midY - transcript.frame.minY
        let leftX = bodyFrame.minX - transcript.frame.minX, inset = bodyFrame.width * 0.1
        let right = origin.withOffset(CGVector(dx: leftX + bodyFrame.width - inset, dy: rowY))
        let left = origin.withOffset(CGVector(dx: leftX + inset, dy: rowY))
        for _ in 0..<16 {
            // Offscreen TextKit hittability can throw instead of returning false.
            if lastText.frame.maxX <= bodyFrame.maxX { break }
            right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        print("Markdown accessibility hierarchy after horizontal scrolling:\n\(app.debugDescription)")
        guard lastText.frame.minX >= bodyFrame.minX, lastText.frame.maxX <= bodyFrame.maxX else {
            XCTFail("Horizontal dragging must fully reveal the final header/column, not clip it.")
            return
        }
        XCTAssertTrue(last.isHittable)
        XCTAssertLessThan(firstText.frame.minX, firstFrame.minX - 30)
        XCTAssertEqual(firstText.frame.width, firstFrame.width, accuracy: 0.5)
        XCTAssertEqual(firstText.frame.height, firstFrame.height, accuracy: 0.5, "Dragging must not scale down table text.")
        XCTAssertEqual(lastText.frame.width, lastFrame.width, accuracy: 0.5)
        XCTAssertEqual(lastText.frame.height, lastFrame.height, accuracy: 0.5)
        XCTAssertEqual(bottom.frame.maxY - top.frame.minY, tableTextHeight, accuracy: 0.5)
        XCTAssertEqual(top.frame.minY, y, accuracy: 2, "A horizontal block drag must not move the table vertically.")
        XCTAssertEqual(user.frame.minY, userY, accuracy: 2, "A horizontal block drag must not move the transcript's reading anchor.")
        XCTAssertEqual(last.value as? String, "Rightmost")
        capture("native-markdown-blocks-last-column", app: app)
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

    private func reachHistoryTop(_ app: XCUIApplication) {
        // Native scroll-to-top is programmatic: it must never request a page.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 180, dy: 10)).tap()
        let first = app.tables["native-transcript"].cells["transcript-message-history-33"]
        let top = app.navigationBars.firstMatch.frame.maxY
        wait(NSPredicate { _, _ in first.exists && abs(first.frame.minY - top) < 5 }, on: first)
    }

    private func pullEarlier(_ table: XCUIElement) {
        table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    func testPagingRequiresPullAndPreservesTheVisibleMessageAndPixelOffset() {
        let app = launch(["--transcript-paging"])
        let table = app.tables["native-transcript"]
        reachHistoryTop(app)
        let anchor = table.cells["transcript-message-history-33"]
        let y = anchor.frame.minY
        let earlier = table.cells["transcript-message-history-32"]
        XCTAssertFalse(earlier.waitForExistence(timeout: 5), "Reaching absolute top must not load older history")
        pullEarlier(table)
        // XCTest waits for the native pull animation to settle before returning
        // from the gesture. Native tests assert the active spinner directly.
        XCTAssertTrue(earlier.waitForExistence(timeout: 10))
        wait(NSPredicate { _, _ in abs(anchor.frame.minY - y) < 3 }, on: anchor)
        XCTAssertEqual(anchor.frame.minY, y, accuracy: 3)
        capture("pull-paging-preserved-reading-anchor", app: app)
    }

    func testFailedHistoryPullCanBeRetriedByAnotherPull() {
        let app = launch(["--transcript-paging", "--transcript-paging-fail-once"])
        let table = app.tables["native-transcript"]
        reachHistoryTop(app)
        pullEarlier(table)
        let earlier = table.cells["transcript-message-history-32"]
        XCTAssertFalse(earlier.waitForExistence(timeout: 6), "The first fixture page intentionally fails")
        // No automatic retry on failure; a separate user gesture retries it.
        pullEarlier(table)
        XCTAssertTrue(earlier.waitForExistence(timeout: 10))
    }
}
