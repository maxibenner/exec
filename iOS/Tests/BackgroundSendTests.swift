import XCTest
import CryptoKit
import ExecRemote
@testable import ExecRemoteStore

@MainActor private final class FakeBackgroundTime: SendBackgroundTime {
    var grants = true
    var expirations: [@MainActor @Sendable () -> Void] = []
    var ended: [Int] = []
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> (() -> Void)? {
        let id = expirations.count
        expirations.append(expiration)
        return grants ? { self.ended.append(id) } : nil
    }
    func expire(_ id: Int = 0) { expirations[id]() }
}

@MainActor final class BackgroundSendTests: XCTestCase {
    private let sync = "/v1/conversations/session/sync"
    private let turns = "/v1/conversations/session/turns"
    private let steer = "/v1/conversations/session/steer"

    private func makeStore(_ transport: any RemoteTransport, _ time: FakeBackgroundTime,
                           deadline: ActionBufferClock = ActionBufferClock(),
                           now: @escaping () -> ContinuousClock.Instant = { .now }) throws -> RemoteStore {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let invitation = try JSONDecoder().decode(PairingInvitation.self, from: JSONEncoder().encode(RemoteJSON.object([
            "version": .number(1), "relay": .string("wss://example.invalid"),
            "route": .string(String(repeating: "a", count: 64)), "hostKey": .string(key),
            "expires": .number(0), "localDevelopment": .bool(false)
        ])))
        let host = PairedHost(invitation: invitation, deviceName: "Background fixture")
        // No wall-clock polling in these tests. Only explicit clock releases run it.
        let observationClock = ActionBufferClock()
        let store = RemoteStore(client: transport, backgroundTime: time, loadHost: { host },
                                saveHost: { _ in }, forgetHost: {},
                                sleep: { _ in try await observationClock.sleep() },
                                bufferNow: now, bufferSleep: { try await deadline.sleep() })
        addTeardownBlock {
            await MainActor.run { store.sceneChanged(.background); time.expirations.forEach { $0() } }
            if let fake = transport as? ActionReadinessTransport { await fake.releaseAll() }
            if let fake = transport as? FakeTransport {
                await fake.releaseConnection(); await fake.releaseRequest()
                await fake.releaseSubscription(); await fake.releaseTeardown()
            }
            await store.suspend()
            await observationClock.advance()
            await deadline.advance()
        }
        return store
    }
    private func until(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<10_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Expected deterministic fixture boundary was not reached")
        throw RemoteFailure("Test synchronization failed.")
    }
    private func ready(_ store: RemoteStore) async {
        await store.connect()
        await store.open("session").value
        store.drafts["session"] = "Last message"
    }
    private func operation(_ id: String, state: String = "running") -> RemoteJSON {
        .object(["id": .string("session"), "messages": .array([]),
                 "operation": .object(["id": .string(id), "state": .string(state)])])
    }

    func testInactiveKeepsObserverAndIdleBackgroundDisconnectsOnlyOnce() async throws {
        let transport = FakeTransport(), time = FakeBackgroundTime()
        await transport.enableChanges()
        let store = try makeStore(transport, time)
        store.sceneChanged(.active)
        try await until { store.lastChangeNotification != nil }
        let generation = store.observationGeneration
        for _ in 0..<3 { store.sceneChanged(.inactive); store.sceneChanged(.active) }
        XCTAssertEqual(store.observationGeneration, generation)
        let connections = await transport.connectionAttempts
        let subscriptions = await transport.subscriptionAttempts
        let disconnects = await transport.disconnections
        XCTAssertEqual(connections, 1)
        XCTAssertEqual(subscriptions, 1)
        XCTAssertEqual(disconnects, 0)
        store.sceneChanged(.background); store.sceneChanged(.background)
        try await until { await transport.disconnections == 1 }
        XCTAssertFalse(store.connected)
        XCTAssertTrue(time.expirations.isEmpty)
        store.sceneChanged(.active)
        try await until { store.lastChangeNotification != nil }
        let newConnections = await transport.connectionAttempts
        let duplicates = await transport.duplicateSubscriptions
        XCTAssertEqual(newConnections, 2)
        XCTAssertEqual(duplicates, 0)
    }

    func testHeldPostBackgroundAcknowledgementEndsGrantWithoutHistoryRead() async throws {
        let transport = ActionReadinessTransport(), time = FakeBackgroundTime()
        let store = try makeStore(transport, time)
        await ready(store)
        await transport.hold("POST", turns)
        let send = store.beginSend()
        XCTAssertEqual(time.expirations.count, 1, "Assertion is acquired before the button action returns")
        try await until { await transport.waiting("POST", self.turns) }
        let readsBefore = await transport.requests.filter { $0.method == "GET" }.count
        store.sceneChanged(.inactive); store.sceneChanged(.background)
        XCTAssertTrue(store.connected)
        XCTAssertTrue(time.ended.isEmpty)
        await transport.hold("GET", sync)
        await transport.release("POST", turns)
        await send?.value
        try await until { await transport.disconnections == 1 }
        XCTAssertEqual(time.ended, [0])
        let readsAfter = await transport.requests.filter { $0.method == "GET" }.count
        let commands = await transport.commands.map(\.key)
        XCTAssertEqual(readsBefore, readsAfter, "No history/model-response read extends the handoff")
        XCTAssertEqual(commands, ["POST " + turns])
        XCTAssertEqual(store.drafts["session"], "")
    }

    func testForegroundAckReleasesAssertionEvenWhenReadbackIsHeld() async throws {
        let transport = ActionReadinessTransport(), time = FakeBackgroundTime()
        let store = try makeStore(transport, time)
        await ready(store)
        await transport.hold("GET", sync)
        let send = store.beginSend()
        try await until { await transport.waiting("GET", self.sync) }
        XCTAssertEqual(time.ended, [0])
        store.sceneChanged(.background)
        try await until { await transport.disconnections == 1 }
        await transport.release("GET", sync)
        await send?.value
        XCTAssertEqual(time.ended, [0])
    }

    func testNoGrantBeforeTaskEntryDoesNotDispatchAndPreservesNewerDraft() async throws {
        let transport = ActionReadinessTransport(), time = FakeBackgroundTime()
        time.grants = false
        let store = try makeStore(transport, time)
        await ready(store)
        let send = store.beginSend()
        store.drafts["session"] = "Newer text"
        store.sceneChanged(.background)
        await send?.value
        try await until { await transport.disconnections == 1 }
        XCTAssertEqual(store.drafts["session"], "Last message\n\nNewer text")
        let commands = await transport.commands
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(time.ended.isEmpty)
    }

    func testNoGrantOrExpirationAfterDispatchIsUncertainAndNeverCancelsHostOrReplays() async throws {
        for granted in [false, true] {
            let transport = ActionReadinessTransport(), time = FakeBackgroundTime()
            time.grants = granted
            let store = try makeStore(transport, time)
            await ready(store)
            await transport.hold("POST", turns)
            let send = store.beginSend()
            try await until { await transport.waiting("POST", self.turns) }
            store.sceneChanged(.background)
            if granted { time.expire() }
            await send?.value
            try await until { await transport.disconnections == 1 }
            XCTAssertEqual(store.drafts["session"], "Last message")
            XCTAssertTrue(store.visibleError?.contains("delivery could not be confirmed") == true)
            XCTAssertFalse(store.canSend, "Uncertain input requires an authoritative foreground read")
            await transport.release("POST", turns)
            store.sceneChanged(.active)
            try await until { store.connected && store.canSend }
            let commands = await transport.commands.map(\.key)
            XCTAssertEqual(commands, ["POST " + turns], "Neither resend nor host cancel is allowed")
            XCTAssertEqual(time.ended, granted ? [0] : [])
        }
    }

    func testOfflineQueuedIntentGetsOneBackgroundConnectionAndInitialAttempt() async throws {
        let transport = ActionReadinessTransport(), time = FakeBackgroundTime()
        let store = try makeStore(transport, time)
        store.selected = "session"; store.drafts["session"] = "Queued offline"
        store.beginSend()
        XCTAssertNotNil(store.pendingMessage)
        store.sceneChanged(.background)
        try await until { time.ended == [0] }
        try await until { await transport.disconnections == 1 }
        let connections = await transport.connectionAttempts
        let requests = await transport.requests.map(\.key)
        XCTAssertEqual(connections, 1)
        XCTAssertEqual(requests, ["GET " + sync, "POST " + turns])
        XCTAssertNil(store.pendingMessage)
    }

    func testElapsedDeadlinePreventsLateTaskEntryOrQueuedDispatchEvenBeforeTimerRuns() async throws {
        for queued in [false, true] {
            let transport = ActionReadinessTransport(), time = FakeBackgroundTime()
            var now = ContinuousClock.now
            let store = try makeStore(transport, time, now: { now })
            if queued {
                store.selected = "session"; store.drafts["session"] = "Last message"
            } else { await ready(store) }
            let send = store.beginSend()
            // Model a suspended process returning before its timer task is serviced.
            now = now.advanced(by: .seconds(3600))
            store.sceneChanged(.background)
            await send?.value
            try await until { time.ended == [0] }
            XCTAssertEqual(store.drafts["session"], "Last message")
            let commands = await transport.commands
            let connections = await transport.connectionAttempts
            XCTAssertTrue(commands.isEmpty)
            XCTAssertEqual(connections, queued ? 0 : 1)
        }
    }

    func testNoGrantCancelsOfflineQueueWithoutConnecting() async throws {
        let transport = ActionReadinessTransport(), time = FakeBackgroundTime()
        time.grants = false
        let store = try makeStore(transport, time)
        store.selected = "session"; store.drafts["session"] = "Queued offline"
        store.beginSend()
        store.drafts["session"] = "Newer"
        store.sceneChanged(.background)
        try await until { await transport.disconnections == 1 }
        XCTAssertNil(store.pendingMessage)
        XCTAssertEqual(store.drafts["session"], "Queued offline\n\nNewer")
        let attempts = await transport.connectionAttempts
        let commands = await transport.commands
        XCTAssertEqual(attempts, 0)
        XCTAssertTrue(commands.isEmpty)
    }

    func testExpirationCancelsOfflineConnectionAndCannotLaterDispatch() async throws {
        let transport = ActionReadinessTransport(), time = FakeBackgroundTime()
        let store = try makeStore(transport, time)
        store.selected = "session"; store.drafts["session"] = "Queued offline"
        await transport.hold("CONNECT", "")
        store.beginSend(); store.sceneChanged(.background)
        try await until { await transport.waiting("CONNECT", "") }
        time.expire()
        try await until { !store.isConnecting }
        try await until { await transport.disconnections == 1 }
        await transport.release("CONNECT", "")
        XCTAssertEqual(time.ended, [0])
        XCTAssertEqual(store.drafts["session"], "Queued offline")
        XCTAssertNil(store.pendingMessage)
        let attempts = await transport.connectionAttempts
        let commands = await transport.commands
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(store.connected)
    }

    func testNewBackgroundHandoffWaitsForOldDisconnectToFinish() async throws {
        let transport = ActionReadinessTransport(), time = FakeBackgroundTime(), deadline = ActionBufferClock()
        let store = try makeStore(transport, time, deadline: deadline)
        await ready(store)
        await transport.hold("DISCONNECT", "")
        store.sceneChanged(.background)
        try await until { await transport.waiting("DISCONNECT", "") }
        store.sceneChanged(.active)
        store.beginSend() // Captured while the old disconnect still owns the transport.
        store.sceneChanged(.background)
        try await until { await deadline.waiting }
        let attemptsBeforeRelease = await transport.connectionAttempts
        XCTAssertEqual(attemptsBeforeRelease, 1)
        await transport.hold("POST", turns)
        await transport.release("DISCONNECT", "")
        try await until { await transport.waiting("POST", self.turns) }
        let attempts = await transport.connectionAttempts
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(time.ended.isEmpty)
        await transport.release("POST", turns)
        try await until { time.ended == [0] }
        try await until { await transport.disconnections == 2 }
        let commands = await transport.commands.map(\.key)
        XCTAssertEqual(commands, ["POST " + turns])
    }

    func testOfflineConnectionFailureRestoresDraftWithoutBackgroundRetry() async throws {
        let transport = ActionReadinessTransport(), time = FakeBackgroundTime()
        await transport.setFailConnections(true)
        let store = try makeStore(transport, time)
        store.selected = "session"; store.drafts["session"] = "Queued offline"
        store.beginSend(); store.sceneChanged(.background)
        try await until { time.ended == [0] }
        try await until { await transport.disconnections == 1 }
        let attempts = await transport.connectionAttempts
        let commands = await transport.commands
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(store.drafts["session"], "Queued offline")
    }

    func testQueuedReadExpirationAndDeadlineStopPredispatchWork() async throws {
        for useDeadline in [false, true] {
            let transport = ActionReadinessTransport(), time = FakeBackgroundTime(), deadline = ActionBufferClock()
            let store = try makeStore(transport, time, deadline: deadline)
            await store.connect()
            store.selected = "session"; store.drafts["session"] = "Queued"
            await transport.hold("GET", sync)
            store.beginSend()
            try await until { await transport.waiting("GET", self.sync) }
            store.drafts["session"] = "Newer"
            store.sceneChanged(.background)
            if useDeadline {
                try await until { await deadline.waiting }
                await deadline.advance()
            } else { time.expire() }
            try await until { await transport.disconnections == 1 }
            await transport.release("GET", sync)
            XCTAssertNil(store.pendingMessage)
            XCTAssertEqual(store.drafts["session"], "Queued\n\nNewer")
            XCTAssertEqual(time.ended, [0])
            let commands = await transport.commands
            XCTAssertTrue(commands.isEmpty)
        }
    }

    func testDependentSteeringSharesGrantAndValidatesOriginalOperation() async throws {
        let transport = ActionReadinessTransport(), time = FakeBackgroundTime()
        let store = try makeStore(transport, time)
        await ready(store)
        await transport.hold("POST", turns)
        let first = store.beginSend()
        try await until { await transport.waiting("POST", self.turns) }
        store.drafts["session"] = "Followup"
        store.beginSend()
        XCTAssertNotNil(store.pendingMessage)
        XCTAssertEqual(time.expirations.count, 1)
        store.sceneChanged(.background)
        await transport.setSnapshot(operation("sent-operation"))
        await transport.hold("POST", steer)
        await transport.release("POST", turns)
        await first?.value
        try await until { await transport.waiting("POST", self.steer) }
        XCTAssertTrue(time.ended.isEmpty)
        await transport.release("POST", steer)
        try await until { time.ended == [0] }
        try await until { await transport.disconnections == 1 }
        let commands = await transport.commands
        XCTAssertEqual(commands.map(\.key), ["POST " + turns, "POST " + steer])
        XCTAssertEqual(commands.last?.body?["operationID"].string, "sent-operation")
    }

    func testQueuedStaleOperationNeverFallsBackToTurn() async throws {
        let transport = ActionReadinessTransport(), time = FakeBackgroundTime()
        let store = try makeStore(transport, time)
        await transport.setSnapshot(operation("original"))
        await ready(store)
        await store.suspend()
        store.beginSend()
        await transport.setSnapshot(operation("replacement"))
        store.sceneChanged(.background)
        try await until { time.ended == [0] }
        XCTAssertEqual(store.drafts["session"], "Last message")
        let commands = await transport.commands
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(store.error?.contains("conversation changed") == true)
    }

    func testRejectedAndNotDispatchedBackgroundSendsReleaseGrantAndRestoreDraft() async throws {
        for kind in [RemoteFailure.Kind.rejected, .notDispatched, .uncertain] {
            let transport = ActionReadinessTransport(), time = FakeBackgroundTime()
            let store = try makeStore(transport, time)
            await ready(store)
            await transport.hold("POST", turns)
            await transport.failNext("POST", turns, disconnect: false, kind: kind)
            let send = store.beginSend()
            try await until { await transport.waiting("POST", self.turns) }
            store.sceneChanged(.background)
            await transport.release("POST", turns)
            await send?.value
            try await until { await transport.disconnections == 1 }
            XCTAssertEqual(time.ended, [0])
            XCTAssertEqual(store.drafts["session"], "Last message")
            XCTAssertEqual(store.canSend, kind != .uncertain)
            let commands = await transport.commands
            XCTAssertEqual(commands.count, 1)
        }
    }

    func testForegroundReturnAndOldExpirationCannotTearDownNewSend() async throws {
        let transport = ActionReadinessTransport(), time = FakeBackgroundTime()
        let store = try makeStore(transport, time)
        await ready(store)
        await transport.hold("POST", turns)
        let first = store.beginSend()
        try await until { await transport.waiting("POST", self.turns) }
        store.sceneChanged(.background); store.sceneChanged(.active)
        // The callback is current, but foreground ownership defeats teardown.
        time.expire()
        XCTAssertTrue(store.connected)
        await transport.release("POST", turns)
        await first?.value
        store.drafts["session"] = "Another message"
        await transport.hold("POST", turns)
        let second = store.beginSend()
        try await until { await transport.waiting("POST", self.turns) }
        store.sceneChanged(.background)
        time.expire(0) // A stale callback must not end assertion 1 or its connection.
        XCTAssertEqual(time.ended, [0])
        XCTAssertTrue(store.connected)
        await transport.release("POST", turns)
        await second?.value
        try await until { await transport.disconnections == 1 }
        XCTAssertEqual(time.ended, [0, 1])
    }

    func testForegroundWinsOverQueuedIdleTeardown() async throws {
        let transport = FakeTransport(), time = FakeBackgroundTime()
        await transport.enableChanges()
        let store = try makeStore(transport, time)
        store.sceneChanged(.active)
        try await until { store.lastChangeNotification != nil }
        await transport.holdNextTeardown()
        store.sceneChanged(.background)
        store.sceneChanged(.active) // Before the queued disconnect can run.
        try await until { await transport.waitingForTeardown }
        await transport.releaseTeardown()
        try await until { await transport.subscriptionAttempts == 2 }
        let disconnects = await transport.disconnections
        let duplicates = await transport.duplicateSubscriptions
        XCTAssertTrue(store.connected)
        XCTAssertEqual(disconnects, 0)
        XCTAssertEqual(duplicates, 0)
    }
}
