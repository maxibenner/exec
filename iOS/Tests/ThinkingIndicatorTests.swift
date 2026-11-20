import XCTest
import ExecRemote
@testable import ExecRemoteStore

/// Deliberately permits cancelled sleepers to finish: stale completions must
/// never resurrect a gap, including a new gap in the same operation.
private actor ThinkingClock {
    var delays: [Double] = []
    var sleepers: [CheckedContinuation<Void, Never>] = []
    func sleep(_ seconds: Double) async {
        delays.append(seconds)
        await withCheckedContinuation { sleepers.append($0) }
    }
    func release() { let pending = sleepers; sleepers = []; for sleeper in pending { sleeper.resume() } }
}

@MainActor final class ThinkingIndicatorTests: XCTestCase {
    private func snapshot(_ id: String = "one", operation: String = "op", state: String = "running",
                          messages: [RemoteJSON] = [], fields: [String: RemoteJSON] = [:]) -> RemoteJSON {
        .object(fields.merging([
            "id": .string(id), "operation": .object(["id": .string(operation), "state": .string(state)]),
            "messages": .array(messages)
        ]) { _, value in value })
    }
    private func settle(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<10_000 { if await condition() { return }; await Task.yield() }
        XCTFail("Lifecycle did not settle")
    }

    func testHalfSecondDelayRepeatedSnapshotsAndResponseGapCancellation() async {
        let clock = ThinkingClock(), lifecycle = ThinkingIndicatorLifecycle(sleep: { await clock.sleep($0) })
        lifecycle.update(snapshot())
        await settle { await clock.delays.count == 1 }
        let delays = await clock.delays
        XCTAssertEqual(delays, [0.5])
        XCTAssertTrue(lifecycle.visible.isEmpty)
        lifecycle.update(snapshot())
        await clock.release()
        await settle { lifecycle.visible == ["one"] }
        let streaming: RemoteJSON = .object(["role": .string("assistant"), "status": .string("streaming"), "text": .string("Answer")])
        lifecycle.update(snapshot(messages: [streaming]))
        XCTAssertTrue(lifecycle.visible.isEmpty)
        lifecycle.update(snapshot()) // Same operation, new gap gets the full delay.
        await settle { await clock.delays.count == 2 }
        XCTAssertTrue(lifecycle.visible.isEmpty)
        lifecycle.update(snapshot(state: "completed"))
        await clock.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(lifecycle.visible.isEmpty)
    }

    func testTerminalToolApprovalAndLocalCancellationHideImmediately() async {
        let clock = ThinkingClock(), lifecycle = ThinkingIndicatorLifecycle(sleep: { await clock.sleep($0) })
        let blocked = [snapshot(state: "failed"), snapshot(state: "interrupted"), snapshot(state: "cancelling"),
                       snapshot(state: "awaiting_approval"), snapshot(fields: ["approval": .object([:])]),
                       snapshot(fields: ["activeToolCallID": .string("tool")]),
                       snapshot(fields: ["activeToolName": .string("delegate")]),
                       snapshot(messages: [.object(["role": .string("tool"), "outcome": .string("running")])])]
        for (index, value) in blocked.enumerated() {
            lifecycle.update(snapshot())
            await settle { await clock.delays.count == index + 1 }
            await clock.release()
            await settle { lifecycle.visible.contains("one") }
            lifecycle.update(value)
            XCTAssertTrue(lifecycle.visible.isEmpty)
        }
        lifecycle.update(snapshot())
        await settle { await clock.delays.count == blocked.count + 1 }
        lifecycle.update(snapshot(), suppressed: true)
        await clock.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(lifecycle.visible.isEmpty)
    }

    func testHiddenSessionsNewOperationsEvictionAndSceneSuspension() async {
        let clock = ThinkingClock(), lifecycle = ThinkingIndicatorLifecycle(sleep: { await clock.sleep($0) })
        lifecycle.update(snapshot("one"))
        lifecycle.update(snapshot("two"))
        await settle { await clock.delays.count == 2 }
        await clock.release()
        await settle { lifecycle.visible == ["one", "two"] }
        // Selection is not a lifecycle input. A hidden session's stream is.
        lifecycle.update(snapshot("one", messages: [.object(["role": .string("assistant"), "status": .string("streaming"), "text": .string("Hidden output")])]))
        XCTAssertEqual(lifecycle.visible, ["two"])
        lifecycle.update(snapshot("two"))
        XCTAssertEqual(lifecycle.visible, ["two"], "Reopening must not restart a delay")
        lifecycle.update(snapshot("two", operation: "replacement"))
        XCTAssertTrue(lifecycle.visible.isEmpty)
        await settle { await clock.delays.count == 3 }
        lifecycle.retain { $0 == "one" }
        lifecycle.update(snapshot("one"))
        await settle { await clock.delays.count == 4 }
        lifecycle.reset()
        await clock.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(lifecycle.visible.isEmpty)
    }

    func testStoreSessionSwitchAndSuspendKeepLifecycleSessionScoped() async {
        let clock = ThinkingClock()
        let store = RemoteStore(client: FakeTransport(), loadHost: { nil }, saveHost: { _ in }, forgetHost: {},
                                thinkingSleep: { await clock.sleep($0) })
        store.connected = true
        store.selected = "one"; store.snapshot = snapshot("one")
        await settle { await clock.delays.count == 1 }
        store.selected = "two"; store.snapshot = snapshot("two", state: "completed")
        await clock.release()
        await settle { store.thinking.visible == ["one"] }
        store.selected = "one"
        XCTAssertEqual(store.thinking.visible, ["one"])
        await store.suspend()
        XCTAssertTrue(store.thinking.visible.isEmpty)
    }
}
