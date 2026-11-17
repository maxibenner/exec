import XCTest
@testable import ExecRemote

final class DelegationTranscriptTests: XCTestCase {
    private let assistant: RemoteJSON = .object([
        "id": .string("assistant"), "role": .string("assistant"), "text": .string(""),
        "calls": .array([
            .object(["id": .string("delegate"), "name": .string("delegate"),
                     "arguments": .object(["tasks": .array([.string("First"), .string("Second")])])]),
            .object(["id": .string("future"), "name": .string("read_file"), "arguments": .object([:])])
        ])
    ])

    private func result(_ indices: [Int], outcome: String = "running") -> RemoteJSON {
        let children: [RemoteJSON] = indices.map { index in
            .object(["taskIndex": .number(Double(index)), "sessionId": .string("child-\(index)"),
                     "outcome": .string(index == 0 ? "failed" : "completed"),
                     "text": .string("Task \(index + 1)\nChild session: child-\(index)\n\nAnswer \(index)")])
        }
        return .object([
            "id": .string("stable-result"), "role": .string("tool"), "callID": .string("delegate"),
            "outcome": .string(outcome), "text": .string(children.compactMap { $0["text"].string }.joined(separator: "\n\n")),
            "details": .object(["type": .string("delegation"), "total": .number(2), "results": .array(children)])
        ])
    }

    private func snapshot(_ messages: [RemoteJSON], active: Bool = true) -> RemoteJSON {
        .object(["id": .string("parent"), "messages": .array(messages),
                 "activeToolCallID": active ? .string("delegate") : .null])
    }

    func testPartialAndTerminalResultsKeepOneRowAndExecutionOwnership() throws {
        let entered = try XCTUnwrap(RemoteTranscriptRow.project(snapshot([assistant])).first)
        XCTAssertTrue(entered.isRunning)
        XCTAssertEqual(entered.message, .null)
        for (indices, outcome, active) in [([1], "running", true), ([0, 1], "running", true),
                                           ([0, 1], "failed", true), ([0, 1], "failed", false),
                                           ([1], "interrupted", false), ([1], "running", false)] {
            let message = result(indices, outcome: outcome)
            let rows = RemoteTranscriptRow.project(snapshot([assistant, message], active: active))
            XCTAssertEqual(rows.count, 1)
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row.id, entered.id)
            XCTAssertEqual(row.call, entered.call)
            XCTAssertEqual(row.message, message) // Includes all structured child details, without child lookups.
            XCTAssertEqual(row.isRunning, active || outcome == "running")
            XCTAssertFalse(row.awaitingApproval)
        }
    }

    func testSyncReplacesMutableDelegateTailIncludingDetailsAndFinalOutcome() throws {
        func page(_ messages: [RemoteJSON], offset: Int, total: Int, reset: Bool, active: Bool) -> RemoteJSON {
            .object(["snapshot": snapshot(messages, active: active), "offset": .number(Double(offset)),
                     "total": .number(Double(total)), "reset": .bool(reset),
                     "prefix": .string(String(repeating: "a", count: 64))])
        }
        var sync = try RemoteTranscriptSync.initial(page([assistant], offset: 0, total: 1, reset: true, active: true))
        let rowID = RemoteTranscriptRow.project(sync.snapshot).first?.id
        sync = try sync.refreshed(page([assistant, result([1])], offset: 0, total: 2, reset: false, active: true))
        for outcome in ["running", "completed"] {
            let message = result([0, 1], outcome: outcome)
            sync = try sync.refreshed(page([message], offset: 1, total: 2, reset: false, active: outcome == "running"))
            XCTAssertEqual(sync.snapshot["messages"].array, [assistant, message])
            let rows = RemoteTranscriptRow.project(sync.snapshot)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows.first?.id, rowID)
            XCTAssertEqual(rows.first?.message, message)
            XCTAssertEqual(rows.first?.isRunning, outcome == "running")
            XCTAssertTrue(sync.refreshPath("/sync").contains("?after=stable-result&prefix="))
        }
    }
}
