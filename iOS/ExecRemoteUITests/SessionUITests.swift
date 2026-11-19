import XCTest
import UIKit

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
    private func assertOfflineBanner(_ app: XCUIApplication, over content: [String: XCUIElement.ElementType], fixedFrame: CGRect? = nil) throws -> [String: XCUIElementSnapshot] {
        let banner = connectionBanner(app)
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertEqual(banner.label, "Host connection lost")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "host-connection-banner").count, 1,
                       "The scene must contain one pill, not one per page or sheet.")
        XCTAssertFalse(app.buttons["Dismiss"].exists, "Connection loss must not have a dismiss action.")
        XCTAssertFalse(element("session-notice", in: app).exists,
                       "Connection loss belongs in the persistent pill, not an action notice.")
        var targets = content
        targets["host-connection-banner"] = .any
        let layout = try stableLayout(app, matching: targets)
        let bannerFrame = try frame("host-connection-banner", in: layout)
        XCTAssertGreaterThan(bannerFrame.height, 0)
        XCTAssertGreaterThan(bannerFrame.minY, app.frame.minY)
        XCTAssertLessThan(bannerFrame.maxY, app.frame.minY + app.frame.height / 4,
                          "The pill stays near the scene's safe top, not its keyboard or bottom inset.")
        if let fixedFrame { assertSameFrame(bannerFrame, fixedFrame) }
        XCTAssertTrue(banner.exists, "Automatic recovery must not precede the offline layout sample.")
        try assertConnectionPill(app, frame: bannerFrame)
        return layout
    }
    private func assertSameFrame(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 1, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 1, file: file, line: line)
    }
    private func assertConnectionPill(_ app: XCUIApplication, frame banner: CGRect) throws {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "connection-pill-\(Int(banner.minY))"
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = try XCTUnwrap(screenshot.image.cgImage)
        let screen = app.frame
        let scale = CGFloat(image.width) / screen.width
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        func rgb(x: CGFloat, y: CGFloat) throws -> [Int] {
            let rect = CGRect(x: ((x - screen.minX) * scale).rounded(.down),
                              y: ((y - screen.minY) * scale).rounded(.down), width: 1, height: 1)
            let pixel = try XCTUnwrap(image.cropping(to: rect))
            var bytes = [UInt8](repeating: 0, count: 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                                     bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return bytes.prefix(3).map(Int.init)
        }
        func matches(_ lhs: [Int], _ rhs: [Int]) -> Bool {
            zip(lhs, rhs).allSatisfy { abs($0 - $1) <= 3 }
        }
        XCTAssertGreaterThan(banner.minX, screen.minX + 12, "The connection indicator must be a pill, not a full-width strip.")
        XCTAssertLessThan(banner.maxX, screen.maxX - 12)
        let fill = try rgb(x: banner.minX + 6, y: banner.midY)
        XCTAssertLessThan(fill.min() ?? 255, 250, "The pill needs its own solid background.")
        XCTAssertGreaterThan(fill[0], fill[1] + 10, "Connection loss should use the error notices' red tint.")
        XCTAssertGreaterThan(fill[0], fill[2] + 10)
        // Sample padding on all four sides, clear of the icon/text.
        for point in [CGPoint(x: banner.maxX - 6, y: banner.midY),
                      CGPoint(x: banner.midX, y: banner.minY + 4),
                      CGPoint(x: banner.midX, y: banner.maxY - 4)] {
            let actual = try rgb(x: point.x, y: point.y)
            XCTAssertTrue(matches(fill, actual), "The pill must have a uniform solid fill: expected \(fill), got \(actual).")
        }
    }
    private func assertConnectionPillSurroundingsUnchanged(_ app: XCUIApplication, before: XCUIScreenshot, frame banner: CGRect) throws {
        let after = app.screenshot()
        for (name, screenshot) in [("offline", before), ("recovered", after)] {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "connection-pill-surroundings-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let beforeImage = try XCTUnwrap(before.image.cgImage)
        let afterImage = try XCTUnwrap(after.image.cgImage)
        XCTAssertEqual(beforeImage.width, afterImage.width)
        XCTAssertEqual(beforeImage.height, afterImage.height)
        let screen = app.frame
        let scale = CGFloat(beforeImage.width) / screen.width
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        // Compare the same side regions on the same settled page. A neighboring
        // row cannot predict their colors: native headers and gradients vary.
        let regions = [CGRect(x: screen.minX + 8, y: banner.minY + 4,
                              width: banner.minX - screen.minX - 16, height: banner.height - 8),
                       CGRect(x: banner.maxX + 8, y: banner.minY + 4,
                              width: screen.maxX - banner.maxX - 16, height: banner.height - 8)]
        for region in regions {
            let rect = CGRect(x: (region.minX - screen.minX) * scale, y: (region.minY - screen.minY) * scale,
                              width: region.width * scale, height: region.height * scale).integral
            func pixels(_ image: CGImage) throws -> [UInt8] {
                let crop = try XCTUnwrap(image.cropping(to: rect))
                var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
                try bytes.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height,
                                                         bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: colorSpace,
                                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                }
                return bytes
            }
            let offline = try pixels(beforeImage), recovered = try pixels(afterImage)
            XCTAssertEqual(offline.count, recovered.count)
            var maximumDifference = 0
            for (index, channels) in zip(offline, recovered).enumerated() where index % 4 != 3 {
                maximumDifference = max(maximumDifference, abs(Int(channels.0) - Int(channels.1)))
            }
            XCTAssertLessThanOrEqual(maximumDifference, 3,
                                     "Showing the pill must not paint over the underlying page beside it: \(region).")
        }
    }
    private func scrollToBottom(_ view: XCUIElement) {
        view.swipeUp()
        view.swipeUp()
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    func testConnectionPillStaysAtTopWhenKeyboardOpens() throws {
        let app = launch(["--offline-actions-fixture"])
        let root = try assertOfflineBanner(app, over: ["All Sessions": .navigationBar])
        let pill = try frame("host-connection-banner", in: root)
        let title = app.navigationBars["All Sessions"].staticTexts["All Sessions"]
        XCTAssertTrue(title.exists)
        XCTAssertLessThan(pill.minY, title.frame.minY,
                          "The pill belongs just below the Dynamic Island safe area, not below navigation.")
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(app.navigationBars["Session 1"].waitForExistence(timeout: 5))
        let composer = element("message-composer", in: app)
        composer.tap(); composer.typeText("Keyboard pill")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let layout = try assertOfflineBanner(app, over: ["chat-composer-controls": .any, "inputView": .any], fixedFrame: pill)
        let back = app.navigationBars["Session 1"].buttons.firstMatch
        XCTAssertTrue(back.exists)
        XCTAssertLessThan(pill.minY, back.frame.midY)
        XCTAssertTrue(back.isHittable, "The top overlay must pass navigation touches through.")
        let controls = try frame("chat-composer-controls", in: layout)
        // inputView includes QuickType, unlike the .keyboard AX key-row frame.
        let keyboard = try frame("inputView", in: layout)
        XCTAssertLessThan(pill.maxY, controls.minY)
        XCTAssertLessThanOrEqual(controls.maxY, keyboard.minY + 1)
        // No re-tap: the overlay must never acquire keyboard focus.
        composer.typeText(" still focused")
        XCTAssertEqual(composer.value as? String, "Keyboard pill still focused")
        app.navigationBars["Session 1"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["All Sessions"].waitForExistence(timeout: 5))
        try assertOfflineBanner(app, over: ["New Session": .button], fixedFrame: pill)
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

    func testOneTopConnectionPillPersistsAcrossNavigationAndNestedSheets() throws {
        let app = launch(["--offline-actions-fixture"])
        let options = app.buttons["Session Options"]
        let newSession = app.buttons["New Session"]
        let targets: [String: XCUIElement.ElementType] = [
            "All Sessions": .navigationBar, "session-list": .any, "Session Options": .button, "New Session": .button
        ]
        let root = try assertOfflineBanner(app, over: targets)
        let pill = try frame("host-connection-banner", in: root)
        let banner = connectionBanner(app)
        // A passive indicator has no hittable AX target. Send real coordinates
        // through its frame instead of asking XCTest to tap the label itself.
        let center = banner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()
        center.press(forDuration: 0.05, thenDragTo: center.withOffset(CGVector(dx: 0, dy: 80)))
        XCTAssertTrue(banner.exists, "Connection loss must not be dismissible by tapping or swiping.")
        XCTAssertTrue(options.isEnabled)
        XCTAssertTrue(newSession.isHittable)

        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(app.navigationBars["Session 1"].waitForExistence(timeout: 5))
        try assertOfflineBanner(app, over: ["Session 1": .navigationBar, "chat-composer-controls": .any], fixedFrame: pill)
        app.navigationBars["Session 1"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["All Sessions"].waitForExistence(timeout: 5))

        options.tap()
        XCTAssertFalse(app.buttons["Reconnect"].exists, "Recovery must not depend on a menu action, even offline.")
        XCTAssertTrue(app.buttons["Forget Host"].isEnabled)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        try assertOfflineBanner(app, over: ["settings-form": .any, "settings-done": .button], fixedFrame: pill)
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
        try assertOfflineBanner(app, over: ["new-session-form": .any, "Create": .button, "Cancel": .button], fixedFrame: pill)
        XCTAssertTrue(app.buttons["new-session-workspace"].label.contains("/Fixture/Workspace"))
        XCTAssertFalse(app.buttons["Create"].isEnabled, "A cached valid draft still requires a connected host.")
        app.buttons["new-session-workspace"].tap()
        let folderBar = app.navigationBars["Choose Folder"]
        XCTAssertTrue(folderBar.waitForExistence(timeout: 5))
        try assertOfflineBanner(app, over: ["host-folder-list": .any, "Choose": .button, "Cancel": .button], fixedFrame: pill)
        XCTAssertTrue(folderBar.buttons["Cancel"].isEnabled)
        folderBar.buttons["Cancel"].tap()
        wait(NSPredicate(format: "exists == false"), on: folderBar)
        app.navigationBars["New Session"].buttons["Cancel"].tap()
        wait(NSPredicate(format: "exists == false"), on: app.navigationBars["New Session"])
        let returned = try assertOfflineBanner(app, over: targets, fixedFrame: pill)
        for name in targets.keys { assertSameFrame(try frame(name, in: returned), try frame(name, in: root)) }
        XCTAssertTrue(options.isHittable)
        XCTAssertTrue(newSession.isHittable)
    }

    private func localBubbles(_ app: XCUIApplication) -> XCUIElementQuery {
        app.tables["native-transcript"].cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript-message-local-"))
    }
    private func cancelQueuedBubble(_ bubble: XCUIElement, app: XCUIApplication) {
        // Use TextKit's selection menu, not a competing context-menu recognizer.
        bubble.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 16)).press(forDuration: 1)
        let cancel = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Cancel Queued Message")).firstMatch
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 2), "Native text selection must retain Copy")
        for _ in 0..<5 {
            if cancel.exists { break }
            // Native edit menus page actions with Forward on this iOS version.
            let forward = app.buttons["Forward"]
            guard forward.exists else { break }
            forward.tap()
        }
        guard cancel.waitForExistence(timeout: 2) else {
            XCTFail("Missing queued-message selection action:\n\(app.debugDescription)")
            return
        }
        capture("queued-bubble-native-selection-menu", app: app)
        cancel.tap()
    }
    private func assertBubbleOpacity(_ app: XCUIApplication, bubble: XCUIElement, opacity: CGFloat) throws {
        try assertBubbleOpacity(app, frame: bubble.frame, opacity: opacity)
    }
    private func assertBubbleOpacity(_ app: XCUIApplication, frame rect: CGRect, opacity: CGFloat) throws {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        func rgb(_ point: CGPoint) throws -> [CGFloat] {
            let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: (point.x * scale).rounded(.down),
                                                               y: (point.y * scale).rounded(.down), width: 1, height: 1)))
            var bytes = [UInt8](repeating: 0, count: 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return bytes.prefix(3).map(CGFloat.init)
        }
        // Sample the bubble's right padding, never a glyph or rounded corner.
        let actual = try rgb(CGPoint(x: rect.maxX - 5, y: rect.midY))
        let background = try rgb(CGPoint(x: rect.minX - 8, y: rect.midY))
        for (index, blue) in [CGFloat(0), 122, 255].enumerated() {
            XCTAssertEqual(actual[index], opacity * blue + (1 - opacity) * background[index], accuracy: 7,
                           "Only the blue/text bubble should be dimmed while queued; RGB=\(actual), background=\(background)")
        }
    }

    func testOfflineSendBuffersOnceAndCancelRestoresBeforeNewerDraft() throws {
        let app = launch(["--offline-actions-fixture"])
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(app.navigationBars["Session 1"].waitForExistence(timeout: 5))
        let composer = app.descendants(matching: .any).matching(identifier: "message-composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        try assertOfflineBanner(app, over: ["Session 1": .navigationBar, "native-transcript": .table, "chat-composer-controls": .any])
        let lastMessage = app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "fixture-1 message 40")).firstMatch
        XCTAssertTrue(lastMessage.waitForExistence(timeout: 5), "Exercise a resident transcript, not an empty offline view.")
        let transcriptLayout = try stableLayout(app, matching: ["transcript-message-message-40": .cell, "chat-composer-controls": .any])
        let lastCell = try frame("transcript-message-message-40", in: transcriptLayout)
        let composerFrame = try frame("chat-composer-controls", in: transcriptLayout)
        XCTAssertLessThanOrEqual(lastMessage.frame.maxY, composerFrame.minY, "The last message bubble must remain above the padded composer, not just above the banner.")
        print("OFFLINE TRANSCRIPT last cell", lastCell, "bubble", lastMessage.frame, "composer", composerFrame)
        XCTAssertFalse(app.buttons["Send"].isEnabled)
        let original = "First offline message"
        let newer = "Newer draft text"
        composer.tap()
        composer.typeText(original)
        wait(NSPredicate(format: "enabled == true"), on: app.buttons["Send"])
        let controls = element("chat-composer-controls", in: app)
        let originalHeight = controls.frame.height
        app.buttons["Send"].tap()

        let pending = localBubbles(app).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        let firstID = pending.identifier
        let bubble = pending.textViews.firstMatch
        XCTAssertEqual(bubble.value as? String, original)
        let queuedLayout = try stableLayout(app, matching: [firstID: .cell, "chat-composer-controls": .any])
        XCTAssertEqual(try frame("chat-composer-controls", in: queuedLayout).height, originalHeight, accuracy: 1,
                       "A queued bubble must not add a composer card or change its height")
        XCTAssertEqual(bubble.frame.minY, app.navigationBars["Session 1"].frame.maxY + 8, accuracy: 3)
        XCTAssertFalse(element("pending-message", in: app).exists)
        XCTAssertFalse(app.buttons["cancel-pending-message"].exists)
        XCTAssertFalse(app.buttons["Stop"].exists, "Unsent display must not invent a running operation")
        try assertBubbleOpacity(app, bubble: bubble, opacity: 0.68)
        composer.tap()
        composer.typeText(newer)
        wait(NSPredicate(format: "value == %@", newer), on: composer)
        XCTAssertEqual(localBubbles(app).count, 1)
        XCTAssertFalse(app.buttons["Send"].isEnabled, "Only one unsent message may be buffered.")
        capture("offline-queued-message", app: app)
        cancelQueuedBubble(bubble, app: app)
        wait(NSPredicate(format: "exists == false"), on: pending)
        let restored = original + "\n\n" + newer
        wait(NSPredicate(format: "value == %@", restored), on: composer)
        XCTAssertTrue(app.buttons["Send"].isEnabled)
        XCTAssertEqual(localBubbles(app).count, 0)
        XCTAssertTrue(connectionBanner(app).exists)
        XCTAssertFalse(element("session-notice", in: app).exists)
        _ = try stableLayout(app, matching: ["transcript-message-message-40": .cell])
        try assertBubbleOpacity(app, bubble: lastMessage, opacity: 1)

        // Leaving the session also returns a NEW unsent bubble to that session's draft.
        app.buttons["Send"].tap()
        let next = localBubbles(app).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertNotEqual(next.identifier, firstID)
        app.navigationBars["Session 1"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["All Sessions"].waitForExistence(timeout: 5))
        XCTAssertFalse(next.exists)
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(app.navigationBars["Session 1"].waitForExistence(timeout: 5))
        wait(NSPredicate(format: "value == %@", restored), on: composer)
        XCTAssertEqual(localBubbles(app).count, 0)
    }

    func testColdOfflineQueuedBubbleExpiresAndNewQueueCanBeCancelled() throws {
        try checkQueuedExpiry(cold: true)
    }
    func testCachedOfflineQueuedBubbleExpiresAndNewQueueCanBeCancelled() throws {
        try checkQueuedExpiry(cold: false)
    }
    private func checkQueuedExpiry(cold: Bool) throws {
        let app = launch(["--offline-actions-fixture", "--offline-expiry-fixture"] + (cold ? ["--cold-offline-fixture"] : []))
        app.buttons["session-fixture-1"].tap()
        let composer = element("message-composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        if cold { XCTAssertEqual(app.tables["native-transcript"].cells.count, 0) }
        XCTAssertFalse(element("session-notice", in: app).exists)
        composer.tap(); composer.typeText("Expiry fixture")
        let originalHeight = element("chat-composer-controls", in: app).frame.height
        app.buttons["Send"].tap()
        let pending = localBubbles(app).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 3))
        let firstID = pending.identifier
        let queuedLayout = try stableLayout(app, matching: [firstID: .cell, "chat-composer-controls": .any])
        XCTAssertEqual(try frame("chat-composer-controls", in: queuedLayout).height, originalHeight, accuracy: 1,
                       "Queuing must not add a composer card, even without a cached transcript")
        let bubble = pending.textViews.firstMatch
        XCTAssertEqual(bubble.frame.minY, app.navigationBars["Session 1"].frame.maxY + 8, accuracy: 3,
                       "A cold queued bubble must pin just like a normal new user turn")
        try assertBubbleOpacity(app, bubble: bubble, opacity: 0.68)
        let queuedFrame = bubble.frame
        composer.tap(); composer.typeText("Newer")
        wait(NSPredicate(format: "value == %@", "Expiry fixture\n\nNewer"), on: composer, timeout: 20)
        wait(NSPredicate(format: "exists == false"), on: app.tables["native-transcript"].cells[firstID])
        XCTAssertEqual(localBubbles(app).count, 0, "Expiry must remove the transient row, including a null-snapshot page")
        XCTAssertFalse(element("session-notice", in: app).exists, "Expiry returns text to the composer without a red notice or toast")
        XCTAssertTrue(app.buttons["Send"].isEnabled)
        XCTAssertTrue(connectionBanner(app).exists)
        if cold {
            XCTAssertEqual(app.tables["native-transcript"].cells.count, 0, "No retained fake snapshot ghost")
            try assertBubbleOpacity(app, frame: queuedFrame, opacity: 0)
        }
        capture(cold ? "cold-queue-expired-no-ghost" : "cached-queue-expired", app: app)
        app.buttons["Send"].tap()
        let next = localBubbles(app).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 3))
        XCTAssertNotEqual(next.identifier, firstID)
        cancelQueuedBubble(next.textViews.firstMatch, app: app)
        wait(NSPredicate(format: "value == %@", "Expiry fixture\n\nNewer"), on: composer)
        XCTAssertEqual(localBubbles(app).count, 0)
        XCTAssertFalse(element("session-notice", in: app).exists, "Native-menu cancellation must also stay silent")
        if cold { XCTAssertEqual(app.tables["native-transcript"].cells.count, 0) }
    }

    func testExpiredQueueKeepsTheLastAssistantReplyReachableAboveAGrowingComposer() throws {
        let app = launch(["--offline-actions-fixture", "--offline-expiry-fixture", "--expiry-scroll-fixture"])
        app.buttons["session-fixture-1"].tap()
        let transcript = app.tables["native-transcript"]
        let composer = element("message-composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        let controls = element("chat-composer-controls", in: app)
        let emptyHeight = controls.frame.height
        let queuedText = "Queued first line\nQueued second line\nQueued third line\nQueued fourth line"
        composer.typeText(queuedText)
        app.buttons["Send"].tap()
        XCTAssertTrue(localBubbles(app).firstMatch.waitForExistence(timeout: 3))
        composer.tap(); composer.typeText("Newer\nNewer again")
        wait(NSPredicate(format: "value == %@", queuedText + "\n\nNewer\nNewer again"), on: composer, timeout: 20)
        XCTAssertEqual(localBubbles(app).count, 0)
        XCTAssertFalse(element("session-notice", in: app).exists)
        XCTAssertGreaterThan(controls.frame.height, emptyHeight + 40, "The returned draft must exercise a larger composer.")
        let reply = transcript.cells["transcript-message-expiry-tail"].textViews.firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        wait(NSPredicate { _, _ in reply.isHittable && reply.frame.maxY <= controls.frame.minY - 4 }, on: reply, timeout: 5)
        transcript.swipeUp()
        wait(NSPredicate { _, _ in reply.isHittable && reply.frame.maxY <= controls.frame.minY - 4 }, on: reply, timeout: 5)
        // Remount with the same expanded draft but without a focused keyboard.
        app.navigationBars["Session 1"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["All Sessions"].waitForExistence(timeout: 5))
        wait(NSPredicate(format: "exists == false"), on: app.keyboards.firstMatch)
        app.buttons["session-fixture-1"].tap()
        XCTAssertTrue(app.navigationBars["Session 1"].waitForExistence(timeout: 5))
        for _ in 0..<4 {
            if reply.exists, reply.isHittable, reply.frame.maxY <= controls.frame.minY - 4 { break }
            transcript.swipeUp(velocity: .fast)
        }
        wait(NSPredicate { _, _ in reply.isHittable && reply.frame.maxY <= controls.frame.minY - 4 }, on: reply, timeout: 5)
        XCTAssertEqual(reply.value as? String, "Latest assistant reply.")
        capture("expired-queue-last-assistant-above-composer", app: app)
    }

    func testRecoveringHostDispatchesQueuedBubbleWithSameIdentityAndFullOpacity() throws {
        let app = launch(["--recovering-host-fixture", "--offline-reconnect-fixture", "--transcript-fixture"])
        app.buttons["session-fixture-1"].tap()
        let composer = element("message-composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("Recover queued input")
        app.buttons["Send"].tap()
        let pending = localBubbles(app).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 3))
        let id = pending.identifier
        _ = try stableLayout(app, matching: [id: .cell])
        XCTAssertTrue(connectionBanner(app).exists)
        try assertBubbleOpacity(app, bubble: pending.textViews.firstMatch, opacity: 0.68)
        XCTAssertFalse(app.buttons["Stop"].exists)
        wait(NSPredicate(format: "exists == false"), on: connectionBanner(app), timeout: 25)
        let answer = app.tables["native-transcript"].cells["transcript-message-streaming-answer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 10), "Fresh validation must automatically drain the unsent message")
        let accepted = app.tables["native-transcript"].cells[id]
        XCTAssertTrue(accepted.exists)
        XCTAssertEqual(localBubbles(app).count, 1)
        XCTAssertEqual(accepted.textViews.firstMatch.value as? String, "Recover queued input")
        // Streaming intentionally changes other row frames on every read; sample
        // the pinned user bubble rather than waiting for a static whole table.
        wait(NSPredicate { _, _ in
            abs(accepted.textViews.firstMatch.frame.minY - app.navigationBars["Session 1"].frame.maxY - 8) < 3
        }, on: accepted)
        try assertBubbleOpacity(app, bubble: accepted.textViews.firstMatch, opacity: 1)
        XCTAssertEqual(accepted.textViews.firstMatch.frame.minY, app.navigationBars["Session 1"].frame.maxY + 8, accuracy: 3)
        XCTAssertFalse(app.tables["native-transcript"].cells["transcript-message-submitted-user"].exists,
                       "Server reconciliation must preserve the local row instead of duplicating it")
        capture("queued-bubble-auto-dispatched-same-row", app: app)
    }

    func testConnectionFailureAndRecoveryPreserveComposerLayoutAndKeyboardFocus() throws {
        // Leave the first real attempt pending long enough to focus the composer,
        // then fail once and recover via the store's ordinary observer loop.
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--recovering-host-fixture", "--delayed-host-failure-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["session-fixture-1"].waitForExistence(timeout: 5))
        app.buttons["session-fixture-1"].tap()
        let composer = element("message-composer", in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap(); composer.typeText("Focus")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let targets: [String: XCUIElement.ElementType] = [
            "Session 1": .navigationBar, "message-composer": .any, "chat-composer-controls": .any, "inputView": .any
        ]
        let pending = try stableLayout(app, matching: targets)
        XCTAssertFalse(connectionBanner(app).exists, "The initial attempt must still be pending, without a pill.")
        XCTAssertTrue(connectionBanner(app).waitForExistence(timeout: 20))
        let failed = try assertOfflineBanner(app, over: targets)
        for name in targets.keys { assertSameFrame(try frame(name, in: failed), try frame(name, in: pending)) }
        composer.typeText(" A") // No re-tap after the window's pill appears.
        XCTAssertEqual(composer.value as? String, "Focus A")

        wait(NSPredicate(format: "exists == false"), on: connectionBanner(app), timeout: 40)
        let recovered = try stableLayout(app, matching: targets)
        for name in targets.keys { assertSameFrame(try frame(name, in: recovered), try frame(name, in: pending)) }
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        composer.typeText(" B") // No re-tap after recovery either.
        XCTAssertEqual(composer.value as? String, "Focus A B")
        XCTAssertFalse(element("session-notice", in: app).exists)
        capture("connection-transitions-preserve-composer-and-focus", app: app)
    }

    func testDelayedFirstStartupConnectsWithoutShowingFailureBanner() throws {
        // Do not use launch(): it waits for the banner to disappear and would
        // accidentally accept a startup flash. This starts with no cached data.
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "--delayed-startup-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["New Session"].waitForExistence(timeout: 5))
        let rootTargets: [String: XCUIElement.ElementType] = [
            "All Sessions": .navigationBar, "session-list": .any, "New Session": .button, "Session Options": .button
        ]
        let pendingRoot = try stableLayout(app, matching: rootTargets)
        let pendingUntil = Date().addingTimeInterval(1.5)
        repeat {
            XCTAssertFalse(connectionBanner(app).exists, "A pending first connection is not a failure.")
            XCTAssertFalse(app.buttons["session-fixture-1"].exists, "The delayed first read must still be pending.")
        } while Date() < pendingUntil
        capture("first-startup-pending-no-banner", app: app)
        app.buttons["New Session"].tap()
        XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Create"].isEnabled, "Verify the first connection is still pending, not already recovered.")
        XCTAssertFalse(connectionBanner(app).exists)
        let sheetTargets: [String: XCUIElement.ElementType] = [
            "New Session": .navigationBar, "new-session-form": .any, "Cancel": .button, "Create": .button
        ]
        let pendingSheet = try stableLayout(app, matching: sheetTargets)
        wait(NSPredicate(format: "enabled == true"), on: app.buttons["Create"], timeout: 15)
        let readySheet = try stableLayout(app, matching: sheetTargets)
        for name in sheetTargets.keys { assertSameFrame(try frame(name, in: readySheet), try frame(name, in: pendingSheet)) }
        XCTAssertFalse(connectionBanner(app).exists)
        XCTAssertFalse(element("session-notice", in: app).exists)
        capture("first-startup-success-no-banner", app: app)
        app.buttons["Cancel"].tap()
        wait(NSPredicate(format: "exists == false"), on: app.navigationBars["New Session"])
        let readyRoot = try stableLayout(app, matching: rootTargets)
        for name in rootTargets.keys { assertSameFrame(try frame(name, in: readyRoot), try frame(name, in: pendingRoot)) }
        XCTAssertFalse(connectionBanner(app).exists)
    }

    func testAutomaticReconnectDoesNotMoveRootControlsOrScrollInsets() throws {
        let app = launch(["--recovering-host-fixture"])
        let targets: [String: XCUIElement.ElementType] = [
            "All Sessions": .navigationBar, "session-list": .any, "New Session": .button,
            "Session Options": .button, "session-fixture-1": .button
        ]
        let offline = try assertOfflineBanner(app, over: targets)
        let list = element("session-list", in: app)
        scrollToBottom(list)
        let offlineEnd = try stableLayout(app, matching: ["session-fixture-12": .button])
        let offlineLastRow = try frame("session-fixture-12", in: offlineEnd)
        XCTAssertLessThanOrEqual(offlineLastRow.maxY, try frame("New Session", in: offline).minY)
        let offlineImage = app.screenshot()
        XCTAssertTrue(connectionBanner(app).exists)

        // No refresh, scene transition or extra scroll: recovery must neither
        // change the usable inset nor move the last row at the scroll limit.
        wait(NSPredicate(format: "exists == false"), on: connectionBanner(app), timeout: 40)
        let onlineEnd = try stableLayout(app, matching: ["session-fixture-12": .button])
        assertSameFrame(try frame("session-fixture-12", in: onlineEnd), offlineLastRow)
        try assertConnectionPillSurroundingsUnchanged(app, before: offlineImage, frame: frame("host-connection-banner", in: offline))
        list.swipeDown()
        list.swipeDown()
        let online = try stableLayout(app, matching: targets)
        for name in targets.keys { assertSameFrame(try frame(name, in: online), try frame(name, in: offline)) }
        XCTAssertFalse(element("session-notice", in: app).exists)
        XCTAssertTrue(app.buttons["New Session"].isHittable)
        capture("host-recovered-unchanged-root-layout", app: app)
    }

    func testAutomaticReconnectDoesNotMoveNewSessionSheetOrScrollInsets() throws {
        let app = launch(["--recovering-host-fixture"])
        app.buttons["New Session"].tap()
        XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 5))
        let targets: [String: XCUIElement.ElementType] = [
            "New Session": .navigationBar, "new-session-form": .any, "Create": .button, "Cancel": .button
        ]
        try assertOfflineBanner(app, over: targets)
        XCTAssertFalse(app.buttons["Create"].isEnabled)
        let form = element("new-session-form", in: app)
        scrollToBottom(form)
        // Scrolling can collapse the native navigation bar. Compare recovery
        // with the settled post-scroll layout, not the initial expanded bar.
        var endTargets = targets
        endTargets["new-session-tool-wait"] = .switch
        let offlineEnd = try stableLayout(app, matching: endTargets)
        let offlineLastRow = try frame("new-session-tool-wait", in: offlineEnd)
        XCTAssertTrue(app.switches["new-session-tool-wait"].isHittable)
        XCTAssertTrue(connectionBanner(app).exists)

        wait(NSPredicate(format: "exists == false"), on: connectionBanner(app), timeout: 40)
        let onlineEnd = try stableLayout(app, matching: endTargets)
        assertSameFrame(try frame("new-session-tool-wait", in: onlineEnd), offlineLastRow)
        for name in targets.keys { assertSameFrame(try frame(name, in: onlineEnd), try frame(name, in: offlineEnd)) }
        wait(NSPredicate(format: "enabled == true"), on: app.buttons["Create"])
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        capture("host-recovered-unchanged-sheet-layout", app: app)
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
