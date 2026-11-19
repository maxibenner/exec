import XCTest
@testable import ExecRemote

final class OptimisticMessageTests: XCTestCase {
    private func user(_ id: String, _ text: String = "Hello") -> RemoteJSON {
        .object(["id": .string(id), "role": .string("user"), "text": .string(text)])
    }
    private func snapshot(_ state: String = "completed", operation: String = "old", messages: [RemoteJSON] = [], pending: [RemoteJSON] = []) -> RemoteJSON {
        .object(["id": .string("chat"), "operation": .object(["id": .string(operation), "state": .string(state)]),
                 "messages": .array(messages), "pendingInput": .array(pending)])
    }
    private func acceptance(_ operation: String = "new", message: String? = nil) -> RemoteJSON {
        .object(["operationID": .string(operation), "messageID": .optional(message)])
    }

    func testSendShowsMessageAndSpinnerBeforeAnyResponseAndKeepsRowIdentity() {
        let initial = snapshot(messages: [user("earlier")])
        var display = RemoteOptimisticMessages()
        let localID = display.begin(text: "Hello", snapshot: initial, id: "local-already-visible-queue")
        XCTAssertEqual(localID, "local-already-visible-queue")
        XCTAssertTrue(RemoteMessageSubmission.isActive(display.project(initial)))
        XCTAssertEqual(RemoteTranscriptRow.project(display.project(initial)).map(\.id), ["earlier", localID])
        display.accept(localID, response: acceptance())
        display.reconcile(initial) // An old poll must not match the earlier identical text.
        XCTAssertTrue(display.awaitingSnapshot)
        let received = snapshot("running", operation: "new", messages: [user("earlier"), user("accepted")])
        display.reconcile(received)
        XCTAssertFalse(display.awaitingSnapshot)
        XCTAssertEqual(RemoteTranscriptRow.project(display.project(received)).map(\.id), ["earlier", localID])
        XCTAssertEqual(initial["messages"].array.count, 1) // No authoritative mutation.
    }

    func testQueuedMessageUsesExactIDAndSurvivesInjectionWithoutDuplicates() {
        let initial = snapshot("running")
        var display = RemoteOptimisticMessages()
        let id = display.begin(text: "Hello", snapshot: initial)
        display.accept(id, response: acceptance("old", message: "queued"))
        display.reconcile(snapshot("running", messages: [user("another-device")]))
        XCTAssertTrue(display.awaitingSnapshot)
        let queued = snapshot("running", pending: [user("queued")])
        display.reconcile(queued)
        XCTAssertEqual(RemoteTranscriptRow.project(display.project(queued)).map(\.id), [id])
        let injected = snapshot("running", messages: [user("queued")], pending: [user("queued")])
        XCTAssertEqual(RemoteTranscriptRow.project(display.project(injected)).map(\.id), [id])
    }

    func testAcceptedSendSurvivesMissingRefreshAndFailureRemovesOnlyLocalRow() {
        let initial = snapshot()
        var display = RemoteOptimisticMessages()
        let id = display.begin(text: "Hello", snapshot: initial)
        display.accept(id, response: acceptance())
        XCTAssertTrue(display.awaitingSnapshot)
        XCTAssertTrue(RemoteMessageSubmission.isActive(display.project(initial)))
        XCTAssertEqual(RemoteTranscriptRow.project(display.project(initial)).count, 1)
        display.remove(id)
        XCTAssertFalse(display.awaitingSnapshot)
        XCTAssertFalse(RemoteMessageSubmission.isActive(display.project(initial)))
        XCTAssertTrue(RemoteTranscriptRow.project(display.project(initial)).isEmpty)
    }

    func testTerminalHostStateRemovesSpinnerEvenForFastTurnsAndErrors() {
        for state in ["completed", "failed", "cancelled", "interrupted"] {
            var display = RemoteOptimisticMessages()
            let id = display.begin(text: "Hello", snapshot: snapshot())
            display.accept(id, response: acceptance())
            let terminal = snapshot(state, operation: "new", messages: [user("accepted")])
            XCTAssertFalse(RemoteMessageSubmission.isActive(display.project(terminal)))
            display.reconcile(terminal)
            XCTAssertFalse(RemoteMessageSubmission.isActive(display.project(terminal)))
            XCTAssertEqual(RemoteTranscriptRow.project(display.project(terminal)).map(\.id), [id])
        }
    }

    func testReconnectionCanReconcileAfterAnotherDeviceStartsANewerTurn() {
        var display = RemoteOptimisticMessages()
        let id = display.begin(text: "Hello", snapshot: snapshot(messages: [user("earlier")]))
        display.accept(id, response: acceptance())
        let later = snapshot(operation: "later-operation", messages: [user("earlier"), user("accepted"), user("later")])
        display.reconcile(later)
        XCTAssertFalse(display.awaitingSnapshot)
        XCTAssertFalse(RemoteMessageSubmission.isActive(display.project(later)))
        XCTAssertEqual(RemoteTranscriptRow.project(display.project(later)).map(\.id), ["earlier", id, "later"])
    }

    private func page(_ snapshot: RemoteJSON, offset: Int = 0, total: Int? = nil, reset: Bool = true) -> RemoteJSON {
        let count = total ?? snapshot["messages"].array.count
        return .object(["snapshot": snapshot, "offset": .number(Double(offset)), "total": .number(Double(count)),
                        "reset": .bool(reset), "prefix": count == 0 ? .null : .string(String(repeating: "a", count: 64))])
    }

    func testAuthoritativeClearRetiresAcceptedInputWithoutResurrectingHistory() throws {
        let cleared: RemoteJSON = .object(["id": .string("chat"), "messages": .array([]), "operation": .null])
        for steering in [false, true] {
            var display = RemoteOptimisticMessages()
            let id = display.begin(text: "Hello", snapshot: snapshot(steering ? "running" : "completed"))
            display.accept(id, response: acceptance(steering ? "old" : "new", message: steering ? "queued" : nil))
            display.reconcile(try RemoteTranscriptSync.initial(page(cleared)))
            XCTAssertFalse(display.awaitingSnapshot)
            XCTAssertEqual(display.project(cleared)["operation"], .null)
            XCTAssertTrue(RemoteTranscriptRow.project(display.project(cleared)).isEmpty)
            display.reconcile(snapshot()) // Navigating through an older cache must not revive input.
            XCTAssertFalse(display.awaitingSnapshot)
        }
    }

    func testResetSuffixRetiresMissingInputAndPreservesExactIdentityForEarlierPages() throws {
        var display = RemoteOptimisticMessages()
        let id = display.begin(text: "Hello", snapshot: snapshot("running"))
        display.accept(id, response: acceptance("old", message: "queued"))
        let suffix = snapshot("running", messages: [user("later", "Later input")])
        display.reconcile(try RemoteTranscriptSync.initial(page(suffix, offset: 10, total: 11)))
        XCTAssertFalse(display.awaitingSnapshot)
        XCTAssertEqual(display.project(suffix)["operation"], suffix["operation"])
        XCTAssertEqual(RemoteTranscriptRow.project(display.project(suffix)).map(\.id), ["later"])
        let expanded = snapshot("running", messages: [user("queued"), user("later", "Later input")])
        display.reconcile(expanded)
        XCTAssertEqual(RemoteTranscriptRow.project(display.project(expanded)).map(\.id), [id, "later"])
    }

    func testCanonicalNewerOperationsWinWithoutBorrowingReplacementTextIdentity() throws {
        for state in ["running", "completed", "failed", "cancelled", "interrupted"] {
            var display = RemoteOptimisticMessages()
            let initial = snapshot(messages: [user("earlier")])
            let id = display.begin(text: "Hello", snapshot: initial)
            display.accept(id, response: acceptance())
            let replacement = snapshot(state, operation: "replacement", messages: [user("unrelated")])
            XCTAssertEqual(display.project(replacement)["operation"], replacement["operation"])
            display.reconcile(try RemoteTranscriptSync.initial(page(replacement)))
            XCTAssertFalse(display.awaitingSnapshot)
            XCTAssertEqual(RemoteTranscriptRow.project(display.project(replacement)).map(\.id), ["unrelated"],
                           "Identical text without history continuity is not the accepted message \(id)")
        }
    }

    func testReadBeforeAcknowledgementCannotResurrectClearedInputOrDuplicateCanonicalRow() throws {
        let cleared: RemoteJSON = .object(["id": .string("chat"), "messages": .array([])])
        for host in [cleared, snapshot("running", operation: "new", messages: [user("queued")])] {
            var display = RemoteOptimisticMessages()
            let id = display.begin(text: "Hello", snapshot: snapshot())
            display.reconcile(try RemoteTranscriptSync.initial(page(host)))
            XCTAssertEqual(display.project(host)["operation"], host["operation"])
            XCTAssertFalse(display.accept(id, response: acceptance(message: "queued")), "The existing authoritative read wins over a late reply")
            XCTAssertFalse(display.awaitingSnapshot)
            XCTAssertEqual(display.project(host)["operation"], host["operation"])
            XCTAssertEqual(RemoteTranscriptRow.project(display.project(host)).map(\.id), host == cleared ? [] : [id])
        }
    }

    func testIncrementalOperationTransitionRetiresInputButSameRunningOperationKeepsIt() throws {
        for state in ["running", "completed"] {
            var display = RemoteOptimisticMessages()
            let initial = snapshot("running", messages: [user("anchor", "Before")])
            let sync = try RemoteTranscriptSync.initial(page(initial))
            let id = display.begin(text: "Hello", snapshot: initial)
            display.accept(id, response: acceptance("old", message: "queued"))
            let current = snapshot(state, messages: [user("anchor", "Before")])
            display.reconcile(try sync.refreshed(page(current, reset: false)))
            XCTAssertEqual(display.awaitingSnapshot, state == "running")
            let newer = snapshot("completed", operation: "newer", messages: [user("anchor", "Before")])
            display.reconcile(try sync.refreshed(page(newer, reset: false)))
            XCTAssertFalse(display.awaitingSnapshot)
            XCTAssertEqual(display.project(newer)["operation"], newer["operation"])
            XCTAssertEqual(RemoteTranscriptRow.project(display.project(newer)).map(\.id), ["anchor"])
        }
    }

    func testCompletedAssistantMessageDoesNotImplyCompletedOperation() {
        let assistant: RemoteJSON = .object(["id": .string("answer"), "role": .string("assistant"),
                                             "text": .string("Answer"), "status": .string("completed")])
        let active = snapshot("running", messages: [assistant])
        XCTAssertTrue(RemoteMessageSubmission.isActive(RemoteOptimisticMessages().project(active)))
    }

    func testReasoningUsesModelCapabilitiesAndPreservesOtherSettings() {
        let model: RemoteJSON = .object(["id": .string("model"), "defaultEffort": .string("high"),
                                         "efforts": .array([.object(["id": .string("high"), "name": .string("High")])])])
        let settings: RemoteJSON = .object(["systemPrompt": .string("Instructions"), "autoApprove": .bool(false),
                                            "searchModel": .string("search"), "effort": .string("high")])
        XCTAssertEqual(RemoteSessionCreation.initialEffort(model: model, settings: settings), "high")
        let body = RemoteSessionCreation.body(workspace: "/workspace", model: model, effort: "high", settings: settings)
        XCTAssertEqual(body["settings"], settings)
        XCTAssertEqual(body["workspace"].string, "/workspace")
        XCTAssertEqual(body["model"].string, "model")
        let unsupported: RemoteJSON = .object(["id": .string("no-reasoning")])
        XCTAssertEqual(RemoteSessionCreation.initialEffort(model: unsupported, settings: settings), "")
        XCTAssertEqual(RemoteSessionCreation.body(workspace: "/workspace", model: unsupported, effort: "high", settings: settings)["settings"]["effort"], .null)
        XCTAssertEqual(RemoteSessionCreation.body(workspace: "/workspace", model: model, effort: "", settings: settings)["settings"]["effort"], .null)
    }
}
