import XCTest
@testable import ExecRemote

final class TranscriptGroupingTests: XCTestCase {
    private func assistant(_ id: String, text: String = "", calls: [String]) -> RemoteJSON {
        .object(["id": .string(id), "role": .string("assistant"), "text": .string(text),
                 "calls": .array(calls.map {
                     .object(["id": .string($0), "name": .string("shell"),
                              "arguments": .object(["command": .string("true")])])
                 })])
    }

    private func result(_ call: String, outcome: String = "completed") -> RemoteJSON {
        .object(["id": .string("result-\(call)"), "role": .string("tool"), "callID": .string(call),
                 "outcome": .string(outcome), "text": .string(outcome)])
    }

    private func snapshot(_ messages: [RemoteJSON], state: String = "running", active: String? = nil,
                          approval: String? = nil, pending: [RemoteJSON] = []) -> RemoteJSON {
        .object(["messages": .array(messages), "operation": .object(["state": .string(state)]),
                 "activeToolCallID": active.map(RemoteJSON.string) ?? .null,
                 "approval": approval.map { .object(["call": .object(["id": .string($0)])]) } ?? .null,
                 "pendingInput": .array(pending)])
    }

    func testAdjacentToolsJoinAcrossHiddenTurnsButVisibleMessagesBreakGroups() {
        let image: RemoteJSON = .object(["id": .string("image"), "role": .string("assistant"),
                                         "images": .array([.object(["id": .string("attachment")])])])
        let steering: RemoteJSON = .object(["id": .string("steering"), "role": .string("user"), "text": .string("Next")])
        let rows = RemoteTranscriptRow.project(snapshot([
            assistant("first", calls: ["a", "b", "speculative"]), result("a"), result("b"),
            assistant("second", calls: ["c"]), result("c"),
            assistant("commentary", text: "Checking another file", calls: ["d"]), result("d"),
            image, assistant("third", calls: ["e"]), result("e")
        ], pending: [steering]))

        XCTAssertEqual(rows.map(\.id), ["tool:first:a", "tool:first:b", "tool:second:c", "commentary",
                                       "tool:commentary:d", "image", "tool:third:e", "steering"])
        XCTAssertEqual(rows.filter { $0.call != nil }.map { [$0.roundsTop, $0.roundsBottom] },
                       [[true, false], [false, false], [false, true], [true, true], [true, true]])
        XCTAssertEqual(rows.last?.message, steering)
    }

    func testPagingAndGroupGrowthReconfigureNeighborsWithoutChangingIdentity() throws {
        let earlier = [assistant("earlier", calls: ["a"]), result("a")]
        let current = [assistant("current", calls: ["b"]), result("b")]
        let later = [assistant("later", calls: ["c"]), result("c")]
        let initial = try XCTUnwrap(RemoteTranscriptRow.project(snapshot(current)).first)
        XCTAssertTrue(initial.roundsTop && initial.roundsBottom)

        let prepended = RemoteTranscriptRow.project(snapshot(earlier + current))
        let afterPaging = try XCTUnwrap(prepended.last)
        XCTAssertEqual(afterPaging.id, initial.id)
        XCTAssertEqual(afterPaging.message, initial.message)
        XCTAssertEqual(afterPaging.call, initial.call)
        XCTAssertFalse(afterPaging.roundsTop)
        XCTAssertTrue(afterPaging.roundsBottom)
        XCTAssertNotEqual(afterPaging, initial) // Existing UIKit row must reconfigure its top edge.

        let appended = RemoteTranscriptRow.project(snapshot(earlier + current + later))
        XCTAssertEqual(appended.map(\.id), ["tool:earlier:a", initial.id, "tool:later:c"])
        XCTAssertEqual(appended[1].message, initial.message)
        XCTAssertFalse(appended[1].roundsTop)
        XCTAssertFalse(appended[1].roundsBottom)
        XCTAssertNotEqual(appended[1], afterPaging) // The old group tail must lose its bottom edge.

        let separated = RemoteTranscriptRow.project(snapshot(earlier + [
            assistant("boundary", text: "Continuing", calls: [])
        ] + current))
        XCTAssertEqual(separated.last, initial)
    }

    func testPendingActivityRequiresExecutionAndNeverOverridesApproval() throws {
        let messages = [assistant("assistant", calls: ["entered", "future"])]
        let approval = try XCTUnwrap(RemoteTranscriptRow.project(snapshot(
            messages, state: "awaiting_approval", approval: "entered"
        )).first)
        XCTAssertTrue(approval.awaitingApproval)
        XCTAssertFalse(approval.isRunning)
        XCTAssertEqual(approval.message, .null)

        let overlapping = RemoteTranscriptRow.project(snapshot(messages, active: "entered", approval: "entered"))
        XCTAssertEqual(overlapping.map(\.id), [approval.id])
        XCTAssertFalse(try XCTUnwrap(overlapping.first).isRunning)

        for state in ["running", "cancelling"] {
            let rows = RemoteTranscriptRow.project(snapshot(messages, state: state, active: "entered"))
            XCTAssertEqual(rows.map(\.id), [approval.id]) // Speculative calls never appear.
            XCTAssertTrue(try XCTUnwrap(rows.first).isRunning)
            XCTAssertFalse(try XCTUnwrap(rows.first).awaitingApproval)
        }
        for state in ["completed", "failed", "interrupted"] {
            XCTAssertTrue(RemoteTranscriptRow.project(snapshot(messages, state: state)).isEmpty)
            // Missing output, even with a leftover active ID, cannot make a terminal operation spin.
            let rows = RemoteTranscriptRow.project(snapshot(messages, state: state, active: "entered"))
            XCTAssertFalse(try XCTUnwrap(rows.first).isRunning)
        }
        XCTAssertTrue(RemoteTranscriptRow.project(snapshot(messages)).isEmpty)
    }

    func testFinishedToolsDoNotSpinAlongsideAnActiveToolOrAfterCancellation() {
        let messages = [assistant("previous", calls: ["done", "failed"]),
                        result("done"), result("failed", outcome: "failed"),
                        assistant("current", calls: ["active", "future"])]
        let running = RemoteTranscriptRow.project(snapshot(messages, active: "active"))
        XCTAssertEqual(running.map(\.id), ["tool:previous:done", "tool:previous:failed", "tool:current:active"])
        XCTAssertEqual(running.map(\.isRunning), [false, false, true])
        XCTAssertEqual(running.map { [$0.roundsTop, $0.roundsBottom] },
                       [[true, false], [false, false], [false, true]])

        let cancelled = RemoteTranscriptRow.project(snapshot(
            messages + [result("active", outcome: "interrupted")], state: "interrupted"
        ))
        XCTAssertEqual(cancelled.map(\.id), running.map(\.id))
        XCTAssertTrue(cancelled.allSatisfy { !$0.isRunning })
        XCTAssertEqual(cancelled.map { [$0.roundsTop, $0.roundsBottom] },
                       running.map { [$0.roundsTop, $0.roundsBottom] })
    }
}
