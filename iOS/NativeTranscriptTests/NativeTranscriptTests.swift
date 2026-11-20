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
        coordinator.update(conversationID: "fixture", snapshot: snapshot(lines: lines), queuedMessage: .null,
                           cancelQueuedMessage: { _ in }, showsThinkingIndicator: thinking, descriptiveShellTitles: false,
                           viewState: TranscriptViewState(generation: 0), table: table)
    }
    private func settle(_ table: TranscriptTableView) async throws {
        // Flush diffable, SwiftUI measurement and the 0.2s follow animator.
        for _ in 0..<12 { table.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
    }
    private func headerY(_ table: TranscriptTableView) throws -> CGFloat {
        try XCTUnwrap(table.rowTop?(toolID)) - table.contentOffset.y
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
