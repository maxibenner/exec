import XCTest
import CryptoKit
import ExecRemote
@testable import ExecRemoteStore

/// No wall-clock sleeps: tests explicitly release each fallback/backoff interval.
private actor ObservationClock {
    private(set) var delays: [Double] = []
    private var waiter: CheckedContinuation<Void, Error>?
    func sleep(_ seconds: Double) async throws {
        try Task.checkCancellation()
        delays.append(seconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
    }
    func advance() { waiter?.resume(); waiter = nil }
    private func cancel() { waiter?.resume(throwing: CancellationError()); waiter = nil }
}

@MainActor final class ChangeNotificationTests: XCTestCase {
    private func makeStore(_ transport: FakeTransport, _ clock: ObservationClock,
                           thinkingSleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) throws -> RemoteStore {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let invitation = try JSONDecoder().decode(PairingInvitation.self, from: JSONEncoder().encode(RemoteJSON.object([
            "version": .number(1), "relay": .string("wss://example.invalid"),
            "route": .string(String(repeating: "a", count: 64)), "hostKey": .string(key),
            "expires": .number(0), "localDevelopment": .bool(false)
        ])))
        let host = PairedHost(invitation: invitation, deviceName: "Notification fixture")
        return RemoteStore(client: transport, loadHost: { host }, saveHost: { _ in }, forgetHost: {},
                           sleep: { try await clock.sleep($0) }, thinkingSleep: thinkingSleep)
    }
    private func notice(_ revision: String = "1", catalog: String = "catalog", epoch: String = "epoch",
                        other: String = "1") -> RemoteChangeNotification {
        .init(epoch: epoch, catalog: catalog, conversations: ["session": revision, "other": other, "unopened": revision])
    }
    private func snapshot(_ id: String = "session", title: String = "Original", messages: [RemoteJSON] = []) -> RemoteJSON {
        .object(["id": .string(id), "title": .string(title), "messages": .array(messages)])
    }
    private func until(_ predicate: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<10_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Observer did not reach the expected state", file: file, line: line)
        throw RemoteFailure("Test synchronization failed.")
    }
    private func configure(_ transport: FakeTransport) async {
        await transport.enableChanges()
        await transport.setSessions(["session", "other", "unopened"].map { .object(["id": .string($0)]) })
        await transport.setConversation(snapshot())
        await transport.setSnapshot(snapshot("other"), for: "other")
        await transport.emit(notice())
    }

    func testIdleAndDuplicateNoticesDoNotPollEvenDuringAnActiveTurn() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport)
        await transport.setConversation(.object(["id": .string("session"), "messages": .array([]),
                                                  "operation": .object(["state": .string("running")])]))
        await store.connect(); await store.open("session").value
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { store.lastChangeNotification == self.notice() }
        let before = await transport.requests
        await transport.emit(notice())
        // This following notice is a processing barrier, but changes only an unopened session.
        let barrier = RemoteChangeNotification(epoch: "epoch", catalog: "catalog",
                                               conversations: ["session": "1", "other": "1", "unopened": "2"])
        await transport.emit(barrier)
        try await until { store.lastChangeNotification == barrier }
        let after = await transport.requests, delays = await clock.delays
        XCTAssertEqual(after, before)
        XCTAssertTrue(delays.isEmpty, "Supported streams should block on notices, not a timer")
        observer.cancel(); await observer.value
        let connected = await transport.isConnected
        XCTAssertFalse(connected)
    }

    func testOnlyChangedResidentRefreshesIncludingHiddenAndActivationStaysWarm() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport)
        await store.connect(); await store.open("session").value; await store.open("other").value
        store.selected = nil
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { store.lastChangeNotification == self.notice() }
        let before = await transport.requests.count
        await transport.setConversation(snapshot(title: "Hidden update"))
        await transport.emit(notice("2"))
        try await until { store.lastChangeNotification == self.notice("2") }
        let changes = await Array(transport.requests.dropFirst(before))
        XCTAssertEqual(changes, ["GET /v1/conversations/session/sync"])
        XCTAssertNil(store.selected)
        await transport.holdNextRequest("GET", "/v1/conversations/session/sync")
        let activation = store.open("session")
        XCTAssertEqual(store.snapshot["title"].string, "Hidden update", "Cache is projected synchronously")
        try await until { await transport.waitingForRequest }
        await transport.releaseRequest(); await activation.value
        let beforeCatalog = await transport.requests.count
        await transport.emit(notice("2", catalog: "catalog-2"))
        try await until { store.lastChangeNotification == self.notice("2", catalog: "catalog-2") }
        let catalog = await Array(transport.requests.dropFirst(beforeCatalog))
        XCTAssertEqual(catalog, ["GET /v1/conversations", "GET /v1/library"])
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.contains("/unopened/sync") })
        observer.cancel(); await observer.value
    }

    func testHiddenThinkingTracksStreamNoticesWithoutDependingOnSelection() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        // The delay itself is covered by ThinkingIndicatorTests' manual clock.
        let store = try makeStore(transport, clock, thinkingSleep: { _ in })
        await configure(transport)
        let gap: RemoteJSON = .object(["id": .string("session"), "messages": .array([]),
            "operation": .object(["id": .string("op"), "state": .string("running")])])
        await transport.setConversation(gap)
        await store.connect(); await store.open("session").value; await store.open("other").value
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { store.lastChangeNotification == self.notice() && store.thinking.visible == ["session"] }
        let streaming: RemoteJSON = .object(["id": .string("session"), "messages": .array([
            .object(["id": .string("answer"), "role": .string("assistant"), "status": .string("streaming"), "text": .string("Hidden output")])]),
            "operation": gap["operation"]])
        await transport.setConversation(streaming)
        await transport.emit(notice("2"))
        try await until { store.lastChangeNotification == self.notice("2") }
        XCTAssertTrue(store.thinking.visible.isEmpty)
        XCTAssertEqual(store.selected, "other")
        await transport.setConversation(gap)
        await transport.emit(notice("3"))
        try await until { store.lastChangeNotification == self.notice("3") && store.thinking.visible == ["session"] }
        await store.open("session").value
        XCTAssertEqual(store.thinking.visible, ["session"], "Opening a warm gap does not restart its delay")
        observer.cancel(); await observer.value
        XCTAssertTrue(store.thinking.visible.isEmpty)
    }

    func testInitialNoticeClosesReadSubscribeRaceAndEpochForcesHiddenCatchup() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport)
        store.selected = "session"
        await transport.holdNextRequest("GET", "/v1/library", captureResponse: true)
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { await transport.waitingForRequest }
        // Initial full reads predate subscription. Its first notice must not be
        // treated merely as a baseline, even if every revision is unchanged.
        await transport.setConversation(snapshot(title: "Between read and subscribe"))
        await transport.setSessions([.object(["id": .string("session")]), .object(["id": .string("new")])])
        await transport.releaseRequest()
        try await until { store.lastChangeNotification == self.notice() }
        XCTAssertEqual(store.snapshot["title"].string, "Between read and subscribe")
        XCTAssertEqual(store.conversations.map(\.id), ["session", "new"])
        store.selected = nil
        let before = await transport.requests.count
        await transport.setConversation(snapshot(title: "New epoch"))
        await transport.emit(notice(epoch: "restarted"))
        try await until { store.lastChangeNotification == self.notice(epoch: "restarted") }
        let reads = await Array(transport.requests.dropFirst(before))
        XCTAssertEqual(reads, ["GET /v1/conversations", "GET /v1/library", "GET /v1/conversations/session/sync"])
        store.selected = "session"
        XCTAssertEqual(store.snapshot["title"].string, "New epoch")
        observer.cancel(); await observer.value
    }

    func testInitialConnectionFailureRecoversWithoutManualConnect() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport)
        await transport.setFailConnections(true)
        store.drafts["session"] = "Keep this unsent draft"
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { await clock.delays.count == 1 }
        XCTAssertFalse(store.connected)
        XCTAssertTrue(store.showsConnectionFailure)
        XCTAssertNil(store.visibleError, "Connection-only failures use the persistent banner, not an action error.")
        XCTAssertEqual(store.reconnectDelay, 3)

        await transport.setFailConnections(false)
        await clock.advance()
        try await until { store.connected && store.lastChangeNotification == self.notice() }
        let attempts = await transport.connectionAttempts
        let commands = await transport.requests.filter { !$0.hasPrefix("GET ") }
        XCTAssertEqual(attempts, 2, "The observer must recover without an explicit connect or refresh action.")
        XCTAssertTrue(commands.isEmpty, "Automatic connection recovery must only read, never infer a mutation retry.")
        XCTAssertEqual(store.drafts["session"], "Keep this unsent draft")
        XCTAssertEqual(store.reconnectDelay, 1.5)
        XCTAssertFalse(store.hasConnectionFailure)
        observer.cancel(); await observer.value
        XCTAssertFalse(store.showsConnectionFailure, "Cancelling observation and scene teardown are not connection failures.")
    }

    func testReconnectCatchesUpHiddenCacheWithUnchangedRevisions() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport)
        await store.connect(); await store.open("session").value
        store.selected = nil; store.drafts["session"] = "Unsent"
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { store.lastChangeNotification == self.notice() }
        await transport.disconnect()
        try await until { await clock.delays.count == 1 }
        await transport.setConversation(snapshot(title: "Changed while disconnected"))
        await clock.advance()
        try await until { store.lastChangeNotification == self.notice() && store.connected }
        let attempts = await transport.connectionAttempts
        XCTAssertEqual(attempts, 2)
        store.selected = "session"
        XCTAssertEqual(store.snapshot["title"].string, "Changed while disconnected")
        XCTAssertEqual(store.drafts["session"], "Unsent")
        XCTAssertEqual(store.reconnectDelay, 1.5)
        observer.cancel(); await observer.value
    }

    func testUnsupportedUsesPollingAndReprobesAfterReconnect() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { await clock.delays.count == 1 }
        let before = await transport.requests.count
        await clock.advance()
        try await until { await clock.delays.count == 2 }
        let reads = await Array(transport.requests.dropFirst(before))
        XCTAssertEqual(reads, ["GET /v1/conversations", "GET /v1/library"])
        await configure(transport); await transport.disconnect(); await clock.advance()
        try await until { await clock.delays.count == 3 }
        await clock.advance()
        try await until { store.lastChangeNotification == self.notice() }
        let subscriptions = await transport.subscriptionAttempts
        XCTAssertEqual(subscriptions, 2)
        observer.cancel(); await observer.value
    }

    func testSubscriptionRejectionNeverFallsBackAndBackoffIsBounded() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport); await transport.rejectChanges("Request rejected.")
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        for (index, delay) in [3.0, 6, 12, 24, 30, 30].enumerated() {
            try await until { await clock.delays.count == index + 1 }
            XCTAssertEqual(store.reconnectDelay, delay)
            XCTAssertTrue(store.showsConnectionFailure, "Subscription failures must latch independently of the socket state.")
            let attempts = await transport.subscriptionAttempts
            let lists = await transport.requests.filter { $0 == "GET /v1/conversations" }.count
            XCTAssertEqual(attempts, index + 1)
            XCTAssertEqual(lists, attempts, "Only initial connection reads; no fallback polling")
            if index < 5 { await clock.advance() }
        }
        await transport.rejectChanges(nil); await clock.advance()
        try await until { store.lastChangeNotification == self.notice() }
        XCTAssertEqual(store.reconnectDelay, 1.5)
        observer.cancel(); await observer.value
    }

    func testMalformedNoticeAndEndedStreamBackOffRatherThanSpinOrPoll() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport); await transport.emit(notice(epoch: ""))
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { await clock.delays.count == 1 }
        XCTAssertEqual(store.error, "Invalid change notification.")
        await clock.advance()
        try await until { await clock.delays.count == 2 }
        XCTAssertEqual(store.reconnectDelay, 6)
        await transport.emit(notice()); await clock.advance()
        try await until { store.lastChangeNotification == self.notice() }
        await transport.endChanges()
        try await until { await clock.delays.count == 3 }
        XCTAssertEqual(store.error, "Change notification stream ended.")
        XCTAssertFalse(store.connected)
        observer.cancel(); await observer.value
    }

    func testNotificationReadRejectionBacksOffEvenWithHealthySocket() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport); await store.connect(); await store.open("session").value
        store.selected = nil
        await transport.failNext("GET", "/v1/conversations/session/sync", disconnect: false)
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { await clock.delays.count == 1 }
        XCTAssertEqual(store.error, "Request rejected.")
        XCTAssertNil(store.lastChangeNotification)
        await transport.failNext("GET", "/v1/conversations/session/sync", disconnect: false)
        await clock.advance()
        try await until { await clock.delays.count == 2 }
        XCTAssertEqual(store.reconnectDelay, 6)
        await clock.advance()
        try await until { store.lastChangeNotification == self.notice() }
        observer.cancel(); await observer.value
    }

    func testSuspensionCancelsInFlightNoticeAndForegroundCatchupIsReadOnly() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport); await store.connect(); await store.open("session").value
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { store.lastChangeNotification == self.notice() }
        await transport.holdNextRequest("GET", "/v1/conversations/session/sync", captureResponse: true)
        await transport.emit(notice("2"))
        try await until { await transport.waitingForRequest }
        await store.suspend()
        await transport.setConversation(snapshot(title: "While suspended"))
        await transport.releaseRequest(); await observer.value
        XCTAssertEqual(store.snapshot["title"].string, "Original")
        XCTAssertFalse(store.connected)
        XCTAssertNil(store.error)
        let foreground = Task { await store.observe() }; defer { foreground.cancel() }
        try await until { store.lastChangeNotification == self.notice("2") }
        XCTAssertEqual(store.snapshot["title"].string, "While suspended")
        let commands = await transport.requests.filter { !$0.hasPrefix("GET ") }
        XCTAssertTrue(commands.isEmpty)
        foreground.cancel(); await foreground.value
    }

    func testUncertainMutationsAreNeverReplayedByNotificationRecovery() async throws {
        for (method, path) in [("POST", "/v1/conversations/session/turns"),
                               ("POST", "/v1/conversations/session/approvals"),
                               ("PATCH", "/v1/library"), ("DELETE", "/v1/conversations/session")] {
            let transport = FakeTransport(), clock = ObservationClock()
            let store = try makeStore(transport, clock)
            await configure(transport); await store.connect(); await store.open("session").value
            let observer = Task { await store.observe() }; defer { observer.cancel() }
            try await until { store.lastChangeNotification == self.notice() }
            await transport.failNext(method, path)
            if path.hasSuffix("/turns") {
                store.drafts["session"] = "Only once"
                await store.send()
                XCTAssertEqual(store.drafts["session"], "Only once")
            } else { await store.mutate(method, path, .object([:])) }
            try await until { await clock.delays.count == 1 }
            await clock.advance()
            try await until { store.lastChangeNotification == self.notice() && store.connected }
            let commands = await transport.requests.filter { !$0.hasPrefix("GET ") }
            XCTAssertEqual(commands, [method + " " + path])
            observer.cancel(); await observer.value
        }
    }

    func testDeletionInvalidatesInFlightCatalogWithoutResurrectingCache() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport); await store.connect(); await store.open("session").value
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { store.lastChangeNotification == self.notice() }
        await transport.holdNextRequest("GET", "/v1/conversations", captureResponse: true)
        await transport.emit(notice("2", catalog: "catalog-2"))
        try await until { await transport.waitingForRequest }
        await store.deleteConversation("session")
        await transport.releaseRequest()
        try await until { store.lastChangeNotification == self.notice("2", catalog: "catalog-2") }
        XCTAssertFalse(store.conversations.contains { $0.id == "session" })
        store.selected = "session"
        XCTAssertEqual(store.snapshot, .null)
        let deletes = await transport.requests.filter { $0.hasPrefix("DELETE ") }
        XCTAssertEqual(deletes.count, 1)
        observer.cancel(); await observer.value
    }

    func testEvictedHistoriesStayUnloadedAndIdleSuspensionStopsObservation() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport)
        let ids = ["evicted", "session", "other", "third", "unopened"]
        await transport.setSessions(ids.map { .object(["id": .string($0)]) })
        for id in ids { await transport.setSnapshot(snapshot(id), for: id) }
        await store.connect()
        for id in ids.prefix(4) { await store.open(id).value }
        store.selected = nil
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { store.lastChangeNotification == self.notice() }
        let before = await transport.requests.count
        let changed = RemoteChangeNotification(epoch: "epoch", catalog: "catalog", conversations: ["evicted": "2", "session": "2", "other": "2", "third": "2", "unopened": "2"])
        await transport.emit(changed)
        try await until { store.lastChangeNotification == changed }
        let reads = await Array(transport.requests.dropFirst(before))
        XCTAssertEqual(reads, ["other", "session", "third"].map { "GET /v1/conversations/\($0)/sync" })
        await store.suspend(); await observer.value
        let suspended = await transport.requests.count
        await transport.emit(notice("3"))
        let after = await transport.requests.count, delays = await clock.delays
        XCTAssertEqual(after, suspended)
        XCTAssertTrue(delays.isEmpty)
        XCTAssertFalse(store.connected)
    }

    func testCoalescedNoticeDuringReadStillCatchesUpToLatestRevision() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport); await store.connect(); await store.open("session").value
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { store.lastChangeNotification == self.notice() }
        await transport.holdNextRequest("GET", "/v1/conversations/session/sync", captureResponse: true)
        await transport.setConversation(snapshot(title: "Revision 2")); await transport.emit(notice("2"))
        try await until { await transport.waitingForRequest }
        await transport.emit(notice("3"))
        await transport.setConversation(snapshot(title: "Revision 4")); await transport.emit(notice("4"))
        await transport.releaseRequest()
        try await until { store.lastChangeNotification == self.notice("4") }
        XCTAssertEqual(store.snapshot["title"].string, "Revision 4")
        observer.cancel(); await observer.value
    }

    func testSendInvalidatesNoticeReadAndPreservesOptimisticRowUntilAcknowledged() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport); await store.connect(); await store.open("session").value
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { store.lastChangeNotification == self.notice() }
        await transport.holdNextRequest("GET", "/v1/conversations/session/sync", captureResponse: true)
        await transport.emit(notice("2"))
        try await until { await transport.waitingForRequest }
        // No authoritative post-send page yet: a successful empty reset now
        // correctly means the host cleared history, not a missing readback.
        await transport.failNext("GET", "/v1/conversations/session/sync", disconnect: false)
        store.drafts["session"] = "Sent once"
        await store.send()
        XCTAssertTrue(store.awaitingSendSnapshot)
        XCTAssertEqual(store.displaySnapshot["pendingInput"].array.first?["text"].string, "Sent once")
        await transport.setConversation(.object([
            "id": .string("session"), "title": .string("After send"),
            "operation": .object(["id": .string("sent-operation"), "state": .string("completed")]),
            "messages": .array([.object(["id": .string("sent-message"), "role": .string("user"), "text": .string("Sent once")])])
        ]))
        await transport.releaseRequest()
        // No new notice: the invalidated revision itself must be caught up again.
        try await until { store.lastChangeNotification == self.notice("2") }
        XCTAssertEqual(store.snapshot["title"].string, "After send")
        XCTAssertFalse(store.awaitingSendSnapshot)
        XCTAssertTrue(store.displaySnapshot["pendingInput"].array.isEmpty)
        XCTAssertEqual(store.displaySnapshot["messages"].array.count, 1)
        XCTAssertEqual(store.drafts["session"], "")
        let sends = await transport.requests.filter { $0.hasPrefix("POST ") }
        XCTAssertEqual(sends, ["POST /v1/conversations/session/turns"])
        observer.cancel(); await observer.value
    }

    func testUncertainSendWithFailedReadStaysDirtyForIdenticalHeartbeatWithoutReplay() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport); await store.connect(); await store.open("session").value
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { store.lastChangeNotification == self.notice() }
        let before = await transport.requests.count
        await transport.failNext("POST", "/v1/conversations/session/turns", disconnect: false)
        await transport.failNext("GET", "/v1/conversations/session/sync", disconnect: false)
        store.drafts["session"] = "Do not replay"
        await store.send()
        XCTAssertTrue(store.connected)
        XCTAssertFalse(store.canSend, "A failed read cannot resolve uncertain delivery")
        let warning = store.visibleError
        XCTAssertTrue(warning?.contains("Message delivery could not be confirmed") == true)
        let failedAttempts = await Array(transport.requests.dropFirst(before))
        XCTAssertEqual(failedAttempts, ["POST /v1/conversations/session/turns", "GET /v1/conversations/session/sync"])
        await transport.emit(notice()) // No revision change; only the dirty mark admits this read.
        try await until { store.canSend }
        XCTAssertEqual(store.visibleError, warning, "Read recovery must preserve the actionable delivery warning")
        XCTAssertEqual(store.drafts["session"], "Do not replay")
        let attempts = await Array(transport.requests.dropFirst(before))
        XCTAssertEqual(attempts, ["POST /v1/conversations/session/turns", "GET /v1/conversations/session/sync", "GET /v1/conversations/session/sync"])
        observer.cancel(); await observer.value
    }

    func testPendingDeletionDoesNotReadDeletedHistoryOrInterruptCommand() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport); await store.connect(); await store.open("session").value
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { store.lastChangeNotification == self.notice() }
        await transport.holdNextRequest("DELETE", "/v1/conversations/session")
        let deletion = Task { await store.deleteConversation("session") }
        try await until { await transport.waitingForRequest }
        let before = await transport.requests.count
        await transport.setSessions([.object(["id": .string("other")])])
        await transport.emit(notice("2", catalog: "deleted"))
        try await until { store.lastChangeNotification == self.notice("2", catalog: "deleted") }
        let reads = await Array(transport.requests.dropFirst(before))
        XCTAssertEqual(reads, ["GET /v1/conversations", "GET /v1/library"])
        XCTAssertTrue(store.connected)
        await transport.releaseRequest(); await deletion.value
        XCTAssertFalse(store.conversations.contains { $0.id == "session" })
        XCTAssertNil(store.error)
        observer.cancel(); await observer.value
    }

    func testReplacementAwaitsSingleSubscriberTeardownWithoutDisconnectingMutation() async throws {
        for stage in ["subscribing", "reading", "idle"] {
            let transport = FakeTransport(), clock = ObservationClock()
            let store = try makeStore(transport, clock)
            await configure(transport); await store.connect(); await store.open("session").value
            if stage == "subscribing" { await transport.holdNextSubscription() }
            let first = Task { await store.observe() }; defer { first.cancel() }
            if stage == "subscribing" {
                try await until { await transport.waitingForSubscription }
            } else {
                try await until { store.lastChangeNotification == self.notice() }
                if stage == "reading" {
                    await transport.holdNextRequest("GET", "/v1/conversations/session/sync")
                    await transport.emit(notice("2"))
                    try await until { await transport.waitingForRequest }
                }
            }
            await transport.holdNextTeardown()
            let generation = store.observationGeneration
            let replacement = Task { await store.observe() }; defer { replacement.cancel() }
            try await until { store.observationGeneration == generation + 1 }
            // Cancellation is deliberately not an immediate transport ownership release.
            if stage == "subscribing" { await transport.releaseSubscription() }
            if stage == "reading" { await transport.releaseRequest() }
            try await until { await transport.waitingForTeardown }
            let subscriptionsBeforeRelease = await transport.subscriptionAttempts
            XCTAssertEqual(subscriptionsBeforeRelease, 1)
            await transport.holdNextRequest("DELETE", "/v1/conversations/unopened")
            let mutation = Task { try await transport.request("DELETE", "/v1/conversations/unopened", body: nil) }
            try await until { await transport.waitingForRequest }
            await transport.releaseTeardown()
            try await until { await transport.subscriptionAttempts == 2 }
            try await until { store.lastChangeNotification == self.notice(stage == "reading" ? "2" : "1") }
            await first.value
            let duplicates = await transport.duplicateSubscriptions, disconnects = await transport.disconnections
            XCTAssertEqual(duplicates, 0, stage)
            XCTAssertEqual(disconnects, 0, stage)
            XCTAssertTrue(store.connected, stage)
            XCTAssertNil(store.error, stage)
            await transport.releaseRequest(); _ = try await mutation.value
            let deletes = await transport.requests.filter { $0.hasPrefix("DELETE ") }
            XCTAssertEqual(deletes, ["DELETE /v1/conversations/unopened"])
            replacement.cancel(); await replacement.value
        }
    }

    func testFailedPendingDeletionCatchesUpOnIdenticalHeartbeatWithoutSpinning() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport); await store.connect(); await store.open("session").value
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { store.lastChangeNotification == self.notice() }
        await transport.holdNextRequest("DELETE", "/v1/conversations/session")
        await transport.failNext("DELETE", "/v1/conversations/session", disconnect: false)
        let deletion = Task { await store.deleteConversation("session") }
        try await until { await transport.waitingForRequest }
        let before = await transport.requests.count
        await transport.setConversation(snapshot(title: "Updated while deletion pending"))
        await transport.emit(notice("2"))
        try await until { store.lastChangeNotification == self.notice("2") }
        let heartbeat = notice("2", other: "2")
        await transport.emit(heartbeat)
        try await until { store.lastChangeNotification == heartbeat }
        let whilePending = await transport.requests.count
        XCTAssertEqual(whilePending, before, "Pending history must neither read nor spin")
        await transport.releaseRequest(); await deletion.value
        XCTAssertTrue(store.conversations.contains { $0.id == "session" })
        XCTAssertEqual(store.error, "Request rejected.")
        store.selected = "session" // project cache without an activation read
        XCTAssertEqual(store.snapshot["title"].string, "Original")
        await transport.emit(heartbeat) // EXACT same revisions, not a reconnect or activation
        try await until { store.snapshot["title"].string == "Updated while deletion pending" }
        let reads = await Array(transport.requests.dropFirst(before))
        XCTAssertEqual(reads, ["GET /v1/conversations/session/sync"])
        let attempts = await transport.connectionAttempts, disconnects = await transport.disconnections
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(disconnects, 0)
        observer.cancel(); await observer.value
    }

    func testNoticeIncrementalRefreshPreservesConcurrentEarlierPage() async throws {
        let transport = FakeTransport(), clock = ObservationClock()
        let store = try makeStore(transport, clock)
        await configure(transport)
        let messages: [RemoteJSON] = (0...80).map { .object(["id": .string("m\($0)"), "role": .string("assistant")]) }
        await transport.setConversation(snapshot(messages: Array(messages.dropLast())))
        await store.connect(); await store.open("session").value
        let observer = Task { await store.observe() }; defer { observer.cancel() }
        try await until { store.lastChangeNotification == self.notice() }
        let path = "/v1/conversations/session/sync?after=m79&prefix=" + String(repeating: "a", count: 64)
        await transport.holdNextRequest("GET", path, captureResponse: true)
        await transport.setConversation(snapshot(messages: messages)); await transport.emit(notice("2"))
        try await until { await transport.waitingForRequest }
        await store.loadEarlier()
        XCTAssertTrue(store.hasEarlierMessages)
        await store.loadEarlier()
        XCTAssertFalse(store.hasEarlierMessages)
        await transport.releaseRequest()
        try await until { store.lastChangeNotification == self.notice("2") }
        XCTAssertEqual(store.snapshot["messages"].array.map { $0["id"].string }, messages.map { $0["id"].string })
        XCTAssertFalse(store.hasEarlierMessages)
        observer.cancel(); await observer.value
    }
}
