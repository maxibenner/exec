import XCTest

@MainActor final class SessionUITests: XCTestCase {
    private func wait(_ predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval = 10) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    private func connectionBanner(_ app: XCUIApplication) -> XCUIElement {
        element("host-connection-banner", in: app)
    }
    private func dragNotice(_ notice: XCUIElement, by offset: CGVector) {
        // Start on the icon/padding, not a text-selection handle.
        let start = notice.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(offset))
    }
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["session-fixture-1"].waitForExistence(timeout: 10))
        if arguments.contains("--offline-actions-fixture") || arguments.contains("--recovering-host-fixture")
            || arguments.contains("--settings-offline") {
            XCTAssertTrue(connectionBanner(app).waitForExistence(timeout: 10))
        } else {
            // Opening New Session is also allowed offline; it is not a readiness signal.
            wait(NSPredicate(format: "exists == false"), on: connectionBanner(app))
        }
        XCTAssertTrue(app.buttons["New Session"].isEnabled)
        return app
    }
    private func descendants(_ snapshot: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        [snapshot] + snapshot.children.flatMap { descendants($0) }
    }
    private func stableLayout(_ app: XCUIApplication, matching targets: [String: XCUIElement.ElementType]) throws -> [String: XCUIElementSnapshot] {
        var previous: [String: CGRect] = [:]
        var unchangedSince = Date()
        var captured: [String: XCUIElementSnapshot]?
        wait(NSPredicate { _, _ in
            // One accessibility snapshot per sample: never mix pre/post-retry
            // frames by waiting for every element to settle sequentially.
            guard let snapshot = try? app.snapshot() else { return false }
            let elements = self.descendants(snapshot)
            var sample: [String: XCUIElementSnapshot] = [:]
            for (name, type) in targets {
                let candidates = elements.filter { type == .any || $0.elementType == type }
                // The frontmost sheet is last; prefer identifiers over labels.
                guard let element = candidates.last(where: { $0.identifier == name })
                    ?? candidates.last(where: { $0.label == name }), !element.frame.isEmpty else { return false }
                sample[name] = element
            }
            let frames = sample.mapValues(\.frame)
            if frames != previous {
                previous = frames
                unchangedSince = Date()
                return false
            }
            guard Date().timeIntervalSince(unchangedSince) >= 0.5 else { return false }
            captured = sample
            return true
        }, on: app)
        return try XCTUnwrap(captured, "The complete layout must settle in one snapshot.")
    }
    private func frame(_ name: String, in layout: [String: XCUIElementSnapshot]) throws -> CGRect {
        try XCTUnwrap(layout[name], "Missing layout element: \(name)").frame
    }
    @discardableResult
    private func assertOfflineBanner(_ app: XCUIApplication, below content: [String: XCUIElement.ElementType]) throws -> [String: XCUIElementSnapshot] {
        let banner = connectionBanner(app)
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertEqual(banner.label, "Host connection lost")
        XCTAssertFalse(app.buttons["Dismiss"].exists, "Connection loss must not have a dismiss action.")
        XCTAssertFalse(element("session-notice", in: app).exists,
                       "Connection loss belongs in the layout banner, not a toast.")
        var targets = content
        targets["host-connection-banner"] = .any
        let layout = try stableLayout(app, matching: targets)
        let bannerFrame = try frame("host-connection-banner", in: layout)
        XCTAssertGreaterThan(bannerFrame.height, 0)
        XCTAssertGreaterThan(bannerFrame.minY, app.frame.midY, "Connection loss belongs at the bottom of the screen.")
        for name in content.keys {
            XCTAssertLessThanOrEqual(try frame(name, in: layout).maxY, bannerFrame.minY + 1,
                                     "The banner must reserve space below lists, forms and controls, not cover them.")
        }
        XCTAssertTrue(banner.exists, "Automatic recovery must not precede the offline layout sample.")
        return layout
    }
    private func assertReclaimedViewport(offline: CGRect, online: CGRect, banner: CGRect, app: XCUIApplication) {
        XCTAssertEqual(offline.maxY, banner.minY, accuracy: 1)
        XCTAssertLessThanOrEqual(online.maxY, app.frame.maxY + 1)
        // Native lists/forms extend under the home indicator again when the
        // banner is gone. Compare usable space, excluding that system inset;
        // the banner's measured bottom is the original safe-area boundary.
        XCTAssertEqual(min(online.maxY, banner.maxY) - offline.maxY, banner.height, accuracy: 2)
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
        XCTAssertFalse(app.buttons["Reconnect"].exists, "Normal connection recovery is automatic.")
        XCTAssertTrue(app.buttons["Forget Host"].isEnabled)
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

    func testOfflineHostBannerKeepsSettingsNewSessionAndFolderAvailable() throws {
        let app = launch(["--offline-actions-fixture"])
        let options = app.buttons["Session Options"]
        let newSession = app.buttons["New Session"]
        try assertOfflineBanner(app, below: ["All Sessions": .navigationBar, "session-list": .any,
                                            "Session Options": .button, "New Session": .button])
        let banner = connectionBanner(app)
        banner.tap()
        banner.swipeDown()
        XCTAssertTrue(banner.exists, "Connection loss must not be dismissible by tapping or swiping.")
        XCTAssertTrue(options.isEnabled)
        XCTAssertTrue(options.isHittable)
        XCTAssertTrue(newSession.isEnabled)
        XCTAssertTrue(newSession.isHittable)

        options.tap()
        XCTAssertFalse(app.buttons["Reconnect"].exists, "Recovery must not depend on a menu action, even offline.")
        XCTAssertTrue(app.buttons["Forget Host"].isEnabled)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        try assertOfflineBanner(app, below: ["settings-form": .any, "settings-done": .button])
        let local = app.switches["descriptive-shell-titles"]
        XCTAssertTrue(local.isEnabled)
        XCTAssertEqual(local.value as? String, "0")
        local.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        wait(NSPredicate(format: "value == %@", "1"), on: local)
        XCTAssertFalse(app.switches["Automatic session titles"].isEnabled)
        XCTAssertFalse(app.textViews["settings-system-prompt"].isEnabled)
        let done = app.buttons["settings-done"]
        XCTAssertEqual(done.label, "Done", "A local preference must not dirty the shared prompt.")
        XCTAssertTrue(done.isEnabled)
        done.tap()
        wait(NSPredicate(format: "exists == false"), on: app.navigationBars["Settings"])

        newSession.tap()
        XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 5))
        try assertOfflineBanner(app, below: ["new-session-form": .any, "Create": .button, "Cancel": .button])
        XCTAssertTrue(app.buttons["new-session-workspace"].label.contains("/Fixture/Workspace"))
        XCTAssertFalse(app.buttons["Create"].isEnabled, "A cached valid draft still requires a connected host.")
        XCTAssertTrue(app.buttons["Cancel"].isEnabled)
        app.buttons["new-session-workspace"].tap()
        let folderBar = app.navigationBars["Choose Folder"]
        XCTAssertTrue(folderBar.waitForExistence(timeout: 5))
        try assertOfflineBanner(app, below: ["host-folder-list": .any, "Choose": .button, "Cancel": .button])
        XCTAssertTrue(folderBar.buttons["Cancel"].isEnabled)
        folderBar.buttons["Cancel"].tap()
        wait(NSPredicate(format: "exists == false"), on: folderBar)
        app.navigationBars["New Session"].buttons["Cancel"].tap()
        wait(NSPredicate(format: "exists == false"), on: app.navigationBars["New Session"])
        XCTAssertTrue(connectionBanner(app).exists, "Closing a sheet must not dismiss the connection banner.")
        XCTAssertTrue(options.isEnabled)
        XCTAssertTrue(newSession.isEnabled)
    }

    func testOfflineSendBuffersOnceAndCancelRestoresBeforeNewerDraft() {
        let app = launch(["--offline-actions-fixture"])
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(app.navigationBars["Session 1"].waitForExistence(timeout: 5))
        let composer = app.descendants(matching: .any).matching(identifier: "message-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Send"].isEnabled)
        let original = "First offline message"
        let newer = "Newer draft text"
        composer.tap()
        composer.typeText(original)
        wait(NSPredicate(format: "enabled == true"), on: app.buttons["Send"])
        app.buttons["Send"].tap()

        let pending = app.descendants(matching: .any).matching(identifier: "pending-message").firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[original].exists)
        let cancel = app.buttons["cancel-pending-message"]
        XCTAssertEqual(cancel.label, "Cancel Queued Message")
        XCTAssertTrue(cancel.isEnabled)
        composer.tap()
        composer.typeText(newer)
        wait(NSPredicate(format: "value == %@", newer), on: composer)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", original)).count, 1)
        XCTAssertFalse(app.buttons["Send"].isEnabled, "Only one unsent message may be buffered.")
        capture("offline-queued-message", app: app)
        cancel.tap()
        wait(NSPredicate(format: "exists == false"), on: pending)
        let restored = original + "\n\n" + newer
        wait(NSPredicate(format: "value == %@", restored), on: composer)
        XCTAssertTrue(app.buttons["Send"].isEnabled)
        XCTAssertEqual(app.tables["native-transcript"].cells.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "transcript-message-local-")).count, 0,
                       "The offline buffer must not appear as a dispatched transcript message.")
        XCTAssertTrue(connectionBanner(app).exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "session-notice").firstMatch.exists)

        // Leaving the session also returns an unsent buffer to that session's draft.
        app.buttons["Send"].tap()
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        app.navigationBars["Session 1"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["All Sessions"].waitForExistence(timeout: 5))
        XCTAssertFalse(pending.exists)
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(app.navigationBars["Session 1"].waitForExistence(timeout: 5))
        wait(NSPredicate(format: "value == %@", restored), on: composer)
    }

    func testAutomaticReconnectReclaimsBottomSpaceBelowRootListAndControls() throws {
        let app = launch(["--recovering-host-fixture"])
        let targets: [String: XCUIElement.ElementType] = [
            "All Sessions": .navigationBar, "session-list": .any, "New Session": .button,
            "Session Options": .button, "session-fixture-1": .button
        ]
        let offline = try assertOfflineBanner(app, below: targets)
        let bannerFrame = try frame("host-connection-banner", in: offline)
        let offlineNavigation = try frame("All Sessions", in: offline)
        let offlineList = try frame("session-list", in: offline)
        let offlineControls = try frame("New Session", in: offline)
        let offlineRow = try frame("session-fixture-1", in: offline)
        print("ROOT OFFLINE FRAMES", offline.mapValues(\.frame))
        capture("host-offline-bottom-layout", app: app)
        XCTAssertTrue(connectionBanner(app).exists, "The offline screenshot must still show the banner.")

        // No Reconnect tap, pull-to-refresh or scene transition may be needed.
        wait(NSPredicate(format: "exists == false"), on: connectionBanner(app), timeout: 40)
        let online = try stableLayout(app, matching: targets)
        let onlineNavigation = try frame("All Sessions", in: online)
        let onlineList = try frame("session-list", in: online)
        let onlineControls = try frame("New Session", in: online)
        let onlineRow = try frame("session-fixture-1", in: online)
        print("ROOT ONLINE FRAMES", online.mapValues(\.frame))
        XCTAssertFalse(connectionBanner(app).exists)
        XCTAssertEqual(onlineNavigation.minY, offlineNavigation.minY, accuracy: 1)
        XCTAssertEqual(onlineRow.minY, offlineRow.minY, accuracy: 1,
                       "A bottom banner must not shift the navigation bar or the first session row.")
        assertReclaimedViewport(offline: offlineList, online: onlineList, banner: bannerFrame, app: app)
        XCTAssertEqual(onlineControls.minY - offlineControls.minY, bannerFrame.height, accuracy: 2,
                       "Controls must reclaim actual layout space, not remain underneath an overlay.")
        let offlineOptions = try frame("Session Options", in: offline)
        let onlineOptions = try frame("Session Options", in: online)
        XCTAssertEqual(onlineOptions.minY - offlineOptions.minY, bannerFrame.height, accuracy: 2)
        XCTAssertFalse(element("session-notice", in: app).exists)
        capture("host-recovered-bottom-layout", app: app)
    }

    func testAutomaticReconnectReclaimsNewSessionSheetBottomSpace() throws {
        let app = launch(["--recovering-host-fixture"])
        app.buttons["New Session"].tap()
        XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 5))
        let targets: [String: XCUIElement.ElementType] = [
            "New Session": .navigationBar, "new-session-form": .any, "Create": .button, "Cancel": .button
        ]
        let offline = try assertOfflineBanner(app, below: targets)
        let bannerFrame = try frame("host-connection-banner", in: offline)
        let offlineNavigation = try frame("New Session", in: offline)
        let offlineForm = try frame("new-session-form", in: offline)
        XCTAssertFalse(try XCTUnwrap(offline["Create"]).isEnabled)
        print("SHEET OFFLINE FRAMES", offline.mapValues(\.frame))
        capture("host-offline-sheet-bottom-layout", app: app)
        XCTAssertTrue(connectionBanner(app).exists, "The offline screenshot must still show the banner.")
        XCTAssertFalse(app.buttons["Create"].isEnabled)

        wait(NSPredicate(format: "exists == false"), on: connectionBanner(app), timeout: 40)
        let online = try stableLayout(app, matching: targets)
        let onlineNavigation = try frame("New Session", in: online)
        let onlineForm = try frame("new-session-form", in: online)
        print("SHEET ONLINE FRAMES", online.mapValues(\.frame))
        XCTAssertFalse(connectionBanner(app).exists)
        XCTAssertEqual(onlineNavigation.minY, offlineNavigation.minY, accuracy: 1)
        XCTAssertEqual(onlineForm.minY, offlineForm.minY, accuracy: 1)
        assertReclaimedViewport(offline: offlineForm, online: onlineForm, banner: bannerFrame, app: app)
        wait(NSPredicate(format: "enabled == true"), on: app.buttons["Create"])
        XCTAssertTrue(app.buttons["Cancel"].isEnabled)
        capture("host-recovered-sheet-bottom-layout", app: app)
        app.buttons["Cancel"].tap()
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
        let notice = element("session-notice", in: app)
        XCTAssertFalse(notice.buttons.firstMatch.exists)
        dragNotice(notice, by: CGVector(dx: 0, dy: 80))
        // The fixture keeps rejecting catalog reads, so another failure can
        // legitimately report a new notice. Dismissing must never move rows.
        XCTAssertEqual(app.buttons["session-fixture-1"].frame.minY, firstRowY, accuracy: 1)
    }
    func testDeletionFailureRestoresSessionAndNoticeDismissesOnlyDownward() {
        let app = launch(["--delete-fails"])
        deleteMiddleSession(app)
        let failure = app.staticTexts["Fixture deletion failed."]
        XCTAssertTrue(failure.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["session-fixture-3"].exists)
        let notice = element("session-notice", in: app)
        XCTAssertTrue(notice.exists)
        XCTAssertFalse(notice.buttons.firstMatch.exists, "Errors must not show an x or dismiss button.")
        XCTAssertFalse(app.buttons["Dismiss"].exists)
        notice.tap()
        XCTAssertTrue(failure.exists, "Normal taps must not dismiss an error.")
        for offset in [CGVector(dx: 120, dy: 0), CGVector(dx: 0, dy: -80), CGVector(dx: 0, dy: 20)] {
            dragNotice(notice, by: offset)
            XCTAssertTrue(failure.exists, "Horizontal, upward and short drags must not dismiss an error.")
        }
        capture("deletion-restored-red-notice", app: app)
        dragNotice(notice, by: CGVector(dx: 0, dy: 80))
        wait(NSPredicate(format: "exists == false"), on: notice)
        XCTAssertTrue(app.buttons["session-fixture-3"].exists, "Dismissing an error must not retry the failed deletion.")
    }
}
