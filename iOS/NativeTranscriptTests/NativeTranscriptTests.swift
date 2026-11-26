import XCTest
import UIKit
import ExecRemote

/// Logic-test runner only: this target compiles the transcript, not the app,
/// RemoteStore or DeviceStore. No account, network, user defaults or screenshots.
@MainActor final class NativeTranscriptTests: XCTestCase {
    private let toolID = "tool:calls:second"
    private func snapshot(lines: Int = 50) -> RemoteJSON {
        let history: [RemoteJSON] = (1...20).map { index in
            .object(["id": .string("history-\(index)"), "role": .string("user"), "text": .string("History \(index)")])
        }
        let calls: [RemoteJSON] = ["first", "second"].map {
            .object(["id": .string($0), "name": .string("shell"), "arguments": .object(["command": .string("echo \($0)")])])
        }
        let results: [RemoteJSON] = ["first", "second"].map {
            .object(["id": .string("result-\($0)"), "role": .string("tool"), "callID": .string($0),
                     "outcome": .string("completed"), "text": .string((1...lines).map { "Output line \($0)" }.joined(separator: "\n"))])
        }
        return .object(["id": .string("fixture"), "messages": .array(history + [
            .object(["id": .string("calls"), "role": .string("assistant"), "calls": .array(calls)])
        ] + results)])
    }

    private func mount() -> (UIWindow, TranscriptTableView, NativeTranscript.Coordinator) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        let table = TranscriptTableView(frame: window.bounds, style: .plain)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 120
        table.selfSizingInvalidation = .enabledIncludingConstraints
        controller.view = table
        window.rootViewController = controller
        let coordinator = NativeTranscript.Coordinator()
        coordinator.attach(table, saveViewState: { _, _ in })
        window.makeKeyAndVisible()
        return (window, table, coordinator)
    }
    private func update(_ coordinator: NativeTranscript.Coordinator, _ table: TranscriptTableView, lines: Int = 50, thinking: Bool = false) {
        coordinator.update(conversationID: "fixture", snapshot: snapshot(lines: lines),
                           showsThinkingIndicator: thinking, descriptiveShellTitles: false,
                           viewState: TranscriptViewState(generation: 0), table: table)
    }
    private func settle(_ table: TranscriptTableView) async throws {
        // Flush diffable, SwiftUI measurement and the 0.2s follow animator.
        for _ in 0..<12 { table.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
    }
    private func headerY(_ table: TranscriptTableView) throws -> CGFloat {
        try XCTUnwrap(table.rowTop?(toolID)) - table.contentOffset.y
    }

    func testEarlierHistoryRequiresNativeRefreshAndRearmsAfterFailure() async throws {
        let (window, table, coordinator) = mount()
        defer { coordinator.detach(table); window.isHidden = true }
        update(coordinator, table)
        try await settle(table)
        var requests = 0
        func configure(_ loading: Bool, hasEarlier: Bool = true) {
            table.configureEarlierHistory(conversationID: "fixture", hasEarlier: hasEarlier,
                                          isLoadingEarlier: loading, loadEarlier: { requests += 1 })
        }
        configure(false)
        let refresh = try XCTUnwrap(table.refreshControl)
        table.beginReaderScroll()
        table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
        table.readerDidScroll()
        table.endReaderScroll()
        try await settle(table)
        XCTAssertEqual(requests, 0, "Reaching the top or laying out must not request history")
        refresh.beginRefreshing()
        XCTAssertEqual(requests, 0, "Programmatic spinner changes must not request history")
        // Drive the native control target directly: this hostless test runner
        // has no UIApplication to dispatch UIControl.sendActions.
        table.pulledEarlierHistory()
        table.pulledEarlierHistory()
        XCTAssertEqual(requests, 1, "Latch before the store publishes its loading flag")
        configure(true)
        table.pulledEarlierHistory()
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(refresh.isRefreshing)
        configure(false) // Failure: unchanged snapshot, still has earlier history.
        XCTAssertFalse(refresh.isRefreshing)
        refresh.beginRefreshing()
        table.pulledEarlierHistory()
        XCTAssertEqual(requests, 2, "A new deliberate pull may retry after failure")
        configure(true)
        configure(false, hasEarlier: false)
        XCTAssertFalse(refresh.isRefreshing)
        XCTAssertNil(table.refreshControl)
        refresh.beginRefreshing()
        table.pulledEarlierHistory()
        XCTAssertEqual(requests, 2, "Exhaustion must not request another page")
        XCTAssertFalse(refresh.isRefreshing)
        configure(false)
        refresh.beginRefreshing()
        table.pulledEarlierHistory()
        configure(true)
        table.configureEarlierHistory(conversationID: "other", hasEarlier: true,
                                      isLoadingEarlier: false, loadEarlier: { requests += 1 })
        XCTAssertFalse(refresh.isRefreshing, "Switching conversations must end the old spinner")
        refresh.beginRefreshing()
        table.pulledEarlierHistory()
        XCTAssertEqual(requests, 4, "A new conversation must not inherit the old request latch")
        table.stopEarlierHistory()
        XCTAssertFalse(refresh.isRefreshing)
        XCTAssertNil(table.refreshControl)
    }

    func testEarlierPrependPreservesTopRowAfterSpinnerCompletion() async throws {
        let (window, table, coordinator) = mount()
        defer { coordinator.detach(table); window.isHidden = true }
        update(coordinator, table)
        try await settle(table)
        table.configureEarlierHistory(conversationID: "fixture", hasEarlier: true,
                                      isLoadingEarlier: false, loadEarlier: {})
        table.beginReaderScroll()
        table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
        table.endReaderScroll()
        try await settle(table)
        let before = try XCTUnwrap(table.rowTop?("history-1")) - table.contentOffset.y
        let refresh = try XCTUnwrap(table.refreshControl)
        refresh.beginRefreshing()
        table.pulledEarlierHistory()
        table.configureEarlierHistory(conversationID: "fixture", hasEarlier: true,
                                      isLoadingEarlier: true, loadEarlier: {})
        let older: RemoteJSON = .object(["id": .string("older"), "role": .string("user"),
                                        "text": .string(String(repeating: "Earlier history\n", count: 20))])
        let prepended: RemoteJSON = .object(["id": .string("fixture"),
                                            "messages": .array([older] + snapshot()["messages"].array)])
        table.configureEarlierHistory(conversationID: "fixture", hasEarlier: false,
                                      isLoadingEarlier: false, loadEarlier: {})
        coordinator.update(conversationID: "fixture", snapshot: prepended,
                           showsThinkingIndicator: false, descriptiveShellTitles: false,
                           viewState: TranscriptViewState(generation: 0), table: table)
        try await settle(table)
        XCTAssertFalse(refresh.isRefreshing)
        XCTAssertEqual(table.scrollState.intent, .reading)
        XCTAssertEqual(try XCTUnwrap(table.rowTop?("history-1")) - table.contentOffset.y, before, accuracy: 1)
    }

    func testGroupedDisclosureAnchorsThroughStreamingInsetsAndCollapse() async throws {
        let (window, table, coordinator) = mount()
        defer { coordinator.detach(table); window.isHidden = true }
        update(coordinator, table)
        try await settle(table)
        XCTAssertEqual(table.scrollState.intent, .latest)
        let y = try headerY(table)
        coordinator.setExpanded(true, rowID: toolID, table: table)
        try await settle(table)
        XCTAssertEqual(table.scrollState.intent, .reading)
        XCTAssertEqual(try headerY(table), y, accuracy: 1)
        XCTAssertGreaterThan(table.contentSize.height - table.contentOffset.y, table.bounds.height + 300)
        update(coordinator, table, lines: 80)
        try await settle(table)
        XCTAssertEqual(try headerY(table), y, accuracy: 1)
        table.contentInset.bottom = 300 // Keyboard/composer clearance.
        try await settle(table)
        XCTAssertEqual(try headerY(table), y, accuracy: 1)
        XCTAssertEqual(table.scrollState.intent, .reading)
        table.contentInset.bottom = 0
        coordinator.setExpanded(false, rowID: toolID, table: table)
        try await settle(table)
        XCTAssertEqual(table.scrollState.intent, .reading)
        coordinator.setExpanded(true, rowID: toolID, table: table)
        try await settle(table)
        XCTAssertEqual(try headerY(table), y, accuracy: 1, "Clamping on collapse must not rearm following")
    }

    func testLayoutAtBottomIsNotReaderReentryButExplicitScrollIs() async throws {
        let (window, table, coordinator) = mount()
        defer { coordinator.detach(table); window.isHidden = true }
        update(coordinator, table)
        try await settle(table)
        coordinator.setExpanded(true, rowID: toolID, table: table)
        try await settle(table)
        table.beginReaderScroll()
        let bottom = TranscriptScrollGeometry.bottom(contentHeight: table.contentSize.height, viewportHeight: table.bounds.height,
                                                       topInset: table.adjustedContentInset.top, bottomInset: table.adjustedContentInset.bottom)
        table.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        table.readerDidScroll() // UIKit bounds/layout callback, not a finger movement.
        table.endReaderScroll()
        XCTAssertEqual(table.scrollState.intent, .reading)
        // The state receives explicit bottom reentry only after the native gesture gate.
        table.scrollState.readerScrolled(towardLatest: true, atBottom: true)
        table.scheduleAlignment()
        try await settle(table)
        let end = table.contentSize.height - table.contentOffset.y
        update(coordinator, table, lines: 90)
        try await settle(table)
        XCTAssertEqual(table.scrollState.intent, .latest)
        XCTAssertEqual(table.contentSize.height - table.contentOffset.y, end, accuracy: 1)
    }

    func testQueuedPromotionKeepsReadingOffsetOrFollowsTheBottom() async throws {
        for reading in [true, false] {
            let (window, table, coordinator) = mount()
            defer { coordinator.detach(table); window.isHidden = true }
            let history = snapshot()["messages"].array
            let queuedID = "local-queued"
            let queued: RemoteJSON = .object(["id": .string(queuedID), "role": .string("user"), "text": .string("Queued input")])
            let reply: RemoteJSON = .object(["id": .string("reply"), "role": .string("assistant"), "text": .string("First chunk")])
            func publish(messages: [RemoteJSON], pending: [RemoteJSON], clearance: CGFloat) {
                table.contentInset.bottom = clearance
                coordinator.update(conversationID: "fixture", snapshot: .object([
                    "id": .string("fixture"), "messages": .array(messages), "pendingInput": .array(pending)
                ]), showsThinkingIndicator: false, descriptiveShellTitles: false,
                   viewState: TranscriptViewState(generation: 0), table: table)
            }
            publish(messages: history, pending: [queued], clearance: 170)
            try await settle(table)
            XCTAssertNil(table.rowTop?(queuedID))
            let before: TranscriptViewportAnchor?
            if reading {
                table.beginReaderScroll()
                table.scrollToRow(at: IndexPath(row: 7, section: 0), at: .top, animated: false)
                table.layoutIfNeeded()
                table.setContentOffset(CGPoint(x: 0, y: table.contentOffset.y + 12), animated: false)
                table.layoutIfNeeded()
                table.endReaderScroll()
                try await settle(table)
                before = try XCTUnwrap(table.readingPosition?())
            } else { before = nil }
            publish(messages: history + [queued, reply], pending: [], clearance: 90)
            try await settle(table)

            XCTAssertNotNil(table.rowTop?(queuedID))
            XCTAssertNil(table.scrollState.reservedTurnID)
            if let before {
                XCTAssertEqual(table.scrollState.intent, .reading)
                let after = try XCTUnwrap(table.readingPosition?())
                XCTAssertEqual(after.rowID, before.rowID)
                XCTAssertEqual(after.offset, before.offset, accuracy: 1)
            } else {
                XCTAssertEqual(table.scrollState.intent, .latest)
                let bottom = TranscriptScrollGeometry.bottom(contentHeight: table.contentSize.height, viewportHeight: table.bounds.height,
                                                              topInset: table.adjustedContentInset.top, bottomInset: table.adjustedContentInset.bottom)
                XCTAssertEqual(table.contentOffset.y, bottom, accuracy: 1)
            }
        }
    }

    func testThinkingLayersStayExactBlueAcrossTintAndAppearanceChanges() async throws {
        let (window, table, coordinator) = mount()
        defer { coordinator.detach(table); window.isHidden = true }
        update(coordinator, table, thinking: true)
        try await settle(table)
        func dots(_ view: UIView) -> [CALayer] {
            (view.layer.sublayers ?? []).filter { $0.bounds.width == 2.5 && $0.bounds.height == 2.5 }
                + view.subviews.flatMap { dots($0) }
        }
        let blue = UIColor(red: 0, green: 122.0 / 255, blue: 1, alpha: 1).cgColor
        for style in [UIUserInterfaceStyle.light, .dark] {
            table.overrideUserInterfaceStyle = style
            table.tintColor = .systemRed
            try await settle(table)
            let layers = dots(try XCTUnwrap(table.tableFooterView))
            XCTAssertEqual(layers.count, 30)
            XCTAssertEqual(layers.filter { $0.backgroundColor == blue }.count, 15)
        }
        update(coordinator, table, thinking: false)
        try await settle(table)
        XCTAssertTrue(table.tableFooterView.map { dots($0).isEmpty } ?? true)
    }
}
