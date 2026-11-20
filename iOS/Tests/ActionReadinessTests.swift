import XCTest
import CryptoKit
import ExecRemote
@testable import ExecRemoteStore

/// Captures command bodies and independently gates acknowledgements and reads.
/// Every matching request stays held until release, including concurrent reads.
private actor ActionReadinessTransport: RemoteTransport {
    struct Request: Sendable {
        let method: String
        let path: String
        let body: RemoteJSON?
        var key: String { method + " " + path }
    }

    private(set) var isConnected = false
    private(set) var requests: [Request] = []
    var commands: [Request] { requests.filter { $0.method != "GET" } }
    private var failConnections = false
    private var failures: [String: (disconnect: Bool, failure: RemoteFailure)] = [:]
    private var snapshots: [String: RemoteJSON] = [:]
    private var held: Set<String> = []
    private var waiters: [String: [UUID: CheckedContinuation<Void, Error>]] = [:]

    func setFailConnections(_ value: Bool) { failConnections = value }
    func setSnapshot(_ value: RemoteJSON) { snapshots[value["id"].string!] = value }
    func failNext(_ method: String, _ path: String, disconnect: Bool = true,
                  kind: RemoteFailure.Kind = .uncertain, message: String? = nil) {
        failures[method + " " + path] = (disconnect, RemoteFailure(message ?? (disconnect ? "Interrupted." : "Request rejected."), kind: kind))
    }
    func hold(_ method: String, _ path: String) { held.insert(method + " " + path) }
    func waiting(_ method: String, _ path: String) -> Bool {
        waiters[method + " " + path]?.isEmpty == false
    }
    func release(_ method: String, _ path: String) {
        let key = method + " " + path
        held.remove(key)
        let pending = waiters.removeValue(forKey: key) ?? [:]
        for waiter in pending.values { waiter.resume() }
    }
    func releaseAll() {
        held.removeAll()
        let pending = waiters.values.flatMap { $0.values }
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    private func waitIfHeld(_ key: String) async throws {
        try Task.checkCancellation()
        guard held.contains(key) else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { waiter.resume(throwing: CancellationError()) }
                else { waiters[key, default: [:]][id] = waiter }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, key: key) }
        }
        try Task.checkCancellation()
    }
    private func cancelWaiter(_ id: UUID, key: String) {
        waiters[key]?.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    func connect(_ host: PairedHost) async throws {
        try await waitIfHeld("CONNECT ")
        if failConnections { throw RemoteFailure("Host unavailable.") }
        isConnected = true
    }
    func disconnect() { isConnected = false }
    func request(_ method: String, _ path: String, body: RemoteJSON?) async throws -> RemoteJSON {
        guard isConnected else { throw RemoteFailure("Disconnected.") }
        requests.append(Request(method: method, path: path, body: body))
        let key = method + " " + path
        try await waitIfHeld(key)
        if let failure = failures.removeValue(forKey: key) {
            if failure.disconnect { isConnected = false }
            throw failure.failure
        }
        guard isConnected else { throw RemoteFailure("Disconnected.") }
        switch (method, path) {
        case ("GET", "/v1/models"): return .array([])
        case ("GET", "/v1/library"): return .object([:])
        case ("GET", "/v1/conversations"):
            return .array(["session", "other"].map { .object(["id": .string($0)]) })
        case ("GET", let path) where path.contains("/sync"):
            let id = String(path.split(separator: "/")[2])
            let snapshot = snapshots[id] ?? .object(["id": .string(id), "messages": .array([])])
            let messages = snapshot["messages"].array
            return .object(["snapshot": snapshot, "offset": .number(0),
                            "total": .number(Double(messages.count)), "reset": .bool(true),
                            "prefix": messages.isEmpty ? .null : .string(String(repeating: "a", count: 64))])
        case ("POST", let path) where path.hasSuffix("/turns") || path.hasSuffix("/steer"):
            return .object(["operationID": .string(body?["operationID"].string ?? "sent-operation"),
                            "messageID": path.hasSuffix("/steer") ? .string("sent-message") : .null])
        case ("POST", "/v1/conversations"): return .object(["id": .string("created")])
        default: return .object([:])
        }
    }
}

/// The buffer deadline is independent of the store's observation/backoff sleep.
private actor ActionBufferClock {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var waiting: Bool { !waiters.isEmpty }
    func sleep() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { waiter.resume(throwing: CancellationError()) }
                else { waiters[id] = waiter }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    func advance() {
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

@MainActor final class ActionReadinessTests: XCTestCase {
    private let sync = "/v1/conversations/session/sync"
    private let turns = "/v1/conversations/session/turns"
    private let steer = "/v1/conversations/session/steer"

    private func makeStore(_ transport: ActionReadinessTransport,
                           clock: ActionBufferClock = ActionBufferClock()) throws -> RemoteStore {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let invitation = try JSONDecoder().decode(PairingInvitation.self, from: JSONEncoder().encode(RemoteJSON.object([
            "version": .number(1), "relay": .string("wss://example.invalid"),
            "route": .string(String(repeating: "a", count: 64)), "hostKey": .string(key),
            "expires": .number(0), "localDevelopment": .bool(false)
        ])))
        let host = PairedHost(invitation: invitation, deviceName: "Action readiness fixture")
        addTeardownBlock {
            await transport.releaseAll()
            await clock.advance()
            await transport.disconnect()
        }
        return RemoteStore(client: transport, loadHost: { host }, saveHost: { _ in }, forgetHost: {},
                           bufferSleep: { try await clock.sleep() })
    }
    private func snapshot(operation: String? = nil, state: String = "running", approval: Bool = false) -> RemoteJSON {
        var fields: [String: RemoteJSON] = ["id": .string("session"), "messages": .array([])]
        if let operation {
            fields["operation"] = .object(["id": .string(operation), "state": .string(state)])
            if approval {
                fields["approval"] = .object(["id": .string("approval"), "operationID": .string(operation)])
            }
        }
        return .object(fields)
    }
    private func ready(_ store: RemoteStore, _ transport: ActionReadinessTransport,
                       snapshot: RemoteJSON? = nil) async {
        await transport.setSnapshot(snapshot ?? self.snapshot())
        await store.connect()
        await store.open("session").value
    }
    private func until(_ predicate: @MainActor () async -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<10_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Store did not reach the expected state", file: file, line: line)
        throw RemoteFailure("Test synchronization failed.")
    }

    func testProviderFailedTurnAllowsAnExplicitNewTurn() async throws {
        let transport = ActionReadinessTransport(), store = try makeStore(transport)
        let failure = "Provider connection failed; the request may have been processed. No retry was made."
        let failed: RemoteJSON = .object([
            "id": .string("session"), "messages": .array([]),
            "operation": .object(["id": .string("failed-operation"), "state": .string("failed"),
                                  "error": .string(failure)])
        ])
        await ready(store, transport, snapshot: failed)
        let initialCommands = await transport.commands
        XCTAssertTrue(initialCommands.isEmpty, "A failed provider operation must not be replayed automatically")
        store.drafts["session"] = "Continue this conversation"
        XCTAssertTrue(store.canSend)
        XCTAssertFalse(store.canStop)
        await store.send()
        let commands = await transport.commands
        XCTAssertEqual(commands.map(\.key), ["POST /v1/conversations/session/turns"],
                       "Explicit continuation must start a new turn, not steer the failed operation")
    }

    func testAuthenticatedHandshakeMakesConnectionReadyBeforeInitialReadsFinish() async throws {
        let transport = ActionReadinessTransport(), store = try makeStore(transport)
        XCTAssertFalse(store.hasLoadedLibrary)
        XCTAssertTrue(store.canReconnect)
        await transport.hold("CONNECT", "")
        await transport.hold("GET", "/v1/models")
        await transport.hold("GET", "/v1/library")
        let connection = Task { await store.connect() }; defer { connection.cancel() }
        try await until { await transport.waiting("CONNECT", "") }
        XCTAssertTrue(store.isConnecting)
        XCTAssertFalse(store.connected)
        XCTAssertFalse(store.canReconnect)
        await transport.release("CONNECT", "")
        try await until { await transport.waiting("GET", "/v1/models") }
        XCTAssertTrue(store.connected, "Readiness is authentication, not completion of catalog reads")
        XCTAssertFalse(store.hasLoadedLibrary)
        XCTAssertFalse(store.hasPendingCommands)
        await transport.release("GET", "/v1/models")
        try await until { await transport.waiting("GET", "/v1/library") }
        XCTAssertFalse(store.hasLoadedLibrary)
        await transport.release("GET", "/v1/library")
        await connection.value
        XCTAssertFalse(store.isConnecting)
        XCTAssertTrue(store.hasLoadedLibrary)
        XCTAssertTrue(store.canForget)
    }

    func testMutationLocksAreScopedAndReleasedBeforeFollowupReads() async throws {
        let transport = ActionReadinessTransport(), store = try makeStore(transport)
        await ready(store, transport)
        let sessionPath = "/v1/conversations/session"
        await transport.hold("PATCH", "/v1/library")
        await transport.hold("POST", "/v1/conversations")
        await transport.hold("PATCH", sessionPath)
        let library = Task { await store.mutate("PATCH", "/v1/library", .object([:])) }
        defer { library.cancel() }
        try await until { await transport.waiting("PATCH", "/v1/library") }
        XCTAssertTrue(store.isSavingLibrary)
        XCTAssertFalse(store.isCreatingSession)
        XCTAssertFalse(store.isUpdatingConversation("session"))
        XCTAssertTrue(store.hasPendingCommands)
        XCTAssertFalse(store.canForget)
        store.drafts["session"] = "Unrelated composer input"
        XCTAssertTrue(store.canSend, "A library write must not disable another action scope")
        var duplicateFinished = false
        let duplicate = Task {
            await store.mutate("PATCH", "/v1/library", .object([:]))
            duplicateFinished = true
        }
        defer { duplicate.cancel() }
        try await until { duplicateFinished } // Duplicate scope must return without dispatching.
        let creation = Task { await store.mutate("POST", "/v1/conversations", .object([:])) }
        let update = Task { await store.mutate("PATCH", sessionPath, .object([:])) }
        defer { creation.cancel(); update.cancel() }
        try await until {
            let creating = await transport.waiting("POST", "/v1/conversations")
            let updating = await transport.waiting("PATCH", sessionPath)
            return creating && updating
        }
        XCTAssertTrue(store.isCreatingSession)
        XCTAssertTrue(store.isUpdatingConversation("session"))
        XCTAssertFalse(store.isUpdatingConversation("other"))
        XCTAssertFalse(store.canDeleteConversation(.object(["id": .string("session")])))
        XCTAssertTrue(store.canDeleteConversation(.object(["id": .string("other")])))
        await transport.hold("GET", sync)
        await transport.release("PATCH", "/v1/library")
        try await until { await transport.waiting("GET", self.sync) }
        XCTAssertFalse(store.isSavingLibrary, "Acknowledged writes must not hold their lock through refresh")
        XCTAssertTrue(store.isCreatingSession)
        await transport.release("POST", "/v1/conversations")
        await transport.release("PATCH", sessionPath)
        try await until { !store.isCreatingSession && !store.isUpdatingConversation("session") }
        XCTAssertFalse(store.hasPendingCommands)
        XCTAssertTrue(store.canForget)
        let commands = await transport.commands
        XCTAssertEqual(commands.map(\.key).sorted(), ["PATCH /v1/library", "PATCH \(sessionPath)", "POST /v1/conversations"].sorted())
        await transport.release("GET", sync)
        await library.value; await creation.value; await update.value
    }

    func testAcceptedOperationCanStopBeforeTranscriptReadback() async throws {
        let transport = ActionReadinessTransport(), store = try makeStore(transport)
        await ready(store, transport)
        store.drafts["session"] = "Start"
        await transport.hold("POST", turns)
        await transport.hold("GET", sync)
        let sending = Task { await store.send() }; defer { sending.cancel() }
        try await until { await transport.waiting("POST", self.turns) }
        XCTAssertTrue(store.hasPendingCommands)
        XCTAssertFalse(store.canStop, "An unacknowledged optimistic row is not a known operation")
        await transport.release("POST", turns)
        try await until { await transport.waiting("GET", self.sync) }
        XCTAssertTrue(store.awaitingSendSnapshot)
        XCTAssertNil(store.snapshot["operation"]["id"].string)
        XCTAssertFalse(store.hasPendingCommands)
        XCTAssertFalse(store.isUpdatingConversation("session"))
        XCTAssertTrue(store.canStop)
        let stopping = Task { await store.stop() }; defer { stopping.cancel() }
        try await until { await transport.commands.contains { $0.path.hasSuffix("/cancel") } }
        let cancel = await transport.commands.first { $0.path.hasSuffix("/cancel") }
        XCTAssertEqual(cancel?.body?["operationID"].string, "sent-operation")
        await transport.release("GET", sync)
        await sending.value; await stopping.value
    }

    func testAuthoritativeResetAfterAcceptanceRetiresOptimisticHistoryAndOperation() async throws {
        for canonical in [snapshot(), snapshot(operation: "newer", state: "completed")] {
            let transport = ActionReadinessTransport(), store = try makeStore(transport)
            await ready(store, transport)
            await transport.hold("POST", turns)
            await transport.hold("GET", sync)
            store.drafts["session"] = "Accepted then cleared"
            let send = Task { await store.send() }; defer { send.cancel() }
            try await until { await transport.waiting("POST", self.turns) }
            await transport.release("POST", turns)
            try await until { await transport.waiting("GET", self.sync) }
            XCTAssertTrue(store.awaitingSendSnapshot)
            XCTAssertTrue(store.canStop)
            await transport.setSnapshot(canonical)
            await transport.release("GET", sync)
            await send.value
            XCTAssertFalse(store.awaitingSendSnapshot)
            XCTAssertEqual(store.displaySnapshot["operation"], canonical["operation"])
            XCTAssertTrue(TranscriptItem.project(store.displaySnapshot).isEmpty)
            XCTAssertFalse(store.active)
            XCTAssertFalse(store.canStop)
            store.selected = "other"; store.selected = "session"
            XCTAssertTrue(TranscriptItem.project(store.displaySnapshot).isEmpty, "A cache visit must not resurrect cleared input")
            let commands = await transport.commands
            XCTAssertEqual(commands.map(\.path), [turns])
        }
    }

    func testCanonicalClearBeforeLateAcknowledgementWinsEvenWhenReadbackFails() async throws {
        let transport = ActionReadinessTransport(), store = try makeStore(transport)
        await ready(store, transport)
        await transport.hold("POST", turns)
        store.drafts["session"] = "Cleared before acknowledgement"
        let send = Task { await store.send() }; defer { send.cancel() }
        try await until { await transport.waiting("POST", self.turns) }
        await store.open("session").value // A current authoritative clear while the reply is delayed.
        await transport.failNext("GET", sync, disconnect: false)
        await transport.release("POST", turns)
        await send.value
        XCTAssertFalse(store.awaitingSendSnapshot)
        XCTAssertFalse(store.active, "A late reply must not install a phantom accepted operation")
        XCTAssertFalse(store.canStop)
        XCTAssertTrue(TranscriptItem.project(store.displaySnapshot).isEmpty)
        XCTAssertNotNil(store.visibleError)
        let commands = await transport.commands
        XCTAssertEqual(commands.map(\.path), [turns])
    }

    func testColdOfflineBufferHasOneSlotAndExplicitCancelRestoresBeforeNewerDraft() async throws {
        let transport = ActionReadinessTransport(), store = try makeStore(transport)
        await transport.setFailConnections(true)
        await store.poll()
        XCTAssertFalse(store.connected)
        XCTAssertNil(store.visibleError, "Connection-only failures belong to the disconnected banner")
        store.selected = "session"
        store.drafts["session"] = " \n "
        XCTAssertFalse(store.canSend)
        store.drafts["session"] = "Buffered"
        XCTAssertTrue(store.canSend, "A paired cold session can accept one local message while offline")
        await store.send()
        let pending = try XCTUnwrap(store.pendingMessage)
        let _: UUID = pending.id
        XCTAssertEqual(pending.conversationID, "session")
        XCTAssertEqual(pending.text, "Buffered")
        XCTAssertEqual(store.drafts["session"], "")
        XCTAssertFalse(store.hasPendingCommands, "The buffer has never been dispatched")
        store.drafts["session"] = "Newer"
        XCTAssertFalse(store.canSend)
        await store.send()
        XCTAssertEqual(store.pendingMessage?.id, pending.id)
        XCTAssertEqual(store.drafts["session"], "Newer")
        store.cancelPendingMessage()
        XCTAssertNil(store.pendingMessage)
        XCTAssertEqual(store.drafts["session"], "Buffered\n\nNewer")
        XCTAssertTrue(store.canSend)
        let commands = await transport.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testQueuedBubbleProjectionIsTransientForColdAndCachedCancelAndExpiry() async throws {
        for cached in [false, true] {
            for expires in [false, true] {
                let transport = ActionReadinessTransport(), clock = ActionBufferClock()
                let store = try makeStore(transport, clock: clock)
                if cached {
                    await ready(store, transport)
                    await transport.disconnect()
                } else { store.selected = "session" }
                store.connected = false
                var presentation = ConversationPresentation(conversationID: "session", catalog: store.conversations,
                                                            snapshot: store.displaySnapshot)
                let baseline = presentation.snapshot
                store.drafts["session"] = "**Literal queued text**"
                await store.send()
                let queued = try XCTUnwrap(store.pendingMessage)
                presentation.update(store.displaySnapshot)
                let items = TranscriptItem.project(presentation.snapshot, queuedMessage: queued.transcriptMessage)
                XCTAssertEqual(items.count, 1)
                XCTAssertEqual(items[0].id, queued.rowID)
                XCTAssertTrue(queued.rowID.hasPrefix("local-"))
                XCTAssertTrue(items[0].isQueued)
                XCTAssertFalse(items[0].isToolGroup)
                XCTAssertEqual(items[0].rows[0].message["role"].string, "user")
                XCTAssertEqual(items[0].rows[0].message["text"].string, queued.text)
                XCTAssertEqual(presentation.snapshot, baseline, "Never retain a fake cold snapshot or queued row")
                XCTAssertEqual(store.snapshot, baseline)
                XCTAssertFalse(store.active)
                XCTAssertFalse(store.canStop)
                XCTAssertFalse(store.awaitingSendSnapshot)
                XCTAssertFalse(RemoteMessageSubmission.showsStop(snapshot: store.displaySnapshot, draft: ""))
                store.drafts["session"] = "Newer"
                if expires {
                    try await until { await clock.waiting }
                    await clock.advance()
                    try await until { store.pendingMessage == nil }
                } else { store.cancelPendingMessage(rowID: queued.rowID) }
                presentation.update(store.displaySnapshot)
                XCTAssertTrue(TranscriptItem.project(presentation.snapshot).isEmpty, "No cold or cached ghost bubble")
                XCTAssertEqual(store.drafts["session"], queued.text + "\n\nNewer")
                XCTAssertNil(store.error, "Cancel and expiry restore input without a new error")
                XCTAssertNil(store.visibleError, "Returning queued input must not display a draft notice")
                store.selected = nil; store.selected = "session"
                XCTAssertEqual(store.snapshot, baseline, "The recent cache must never contain the queue")
                await store.send()
                let replacement = try XCTUnwrap(store.pendingMessage)
                XCTAssertNotEqual(replacement.rowID, queued.rowID)
                store.cancelPendingMessage(rowID: queued.rowID)
                XCTAssertEqual(store.pendingMessage?.id, replacement.id, "A stale menu cannot cancel a newer queue")
                store.cancelPendingMessage(rowID: replacement.rowID)
                let commands = await transport.commands
                XCTAssertTrue(commands.isEmpty)
            }
        }
    }

    func testQueuedDispatchKeepsOneRowThroughAcknowledgementReadbackAndReconciliation() async throws {
        for steering in [false, true] {
            let transport = ActionReadinessTransport(), store = try makeStore(transport)
            if steering {
                await ready(store, transport, snapshot: snapshot(operation: "original"))
                await transport.disconnect()
            } else { store.selected = "session" }
            store.connected = false
            store.drafts["session"] = "Queued input"
            await store.send()
            let queued = try XCTUnwrap(store.pendingMessage)
            let path = steering ? steer : turns
            await transport.setSnapshot(snapshot(operation: steering ? "original" : nil))
            await transport.hold("GET", sync)
            await transport.hold("POST", path)
            let reconnect = Task { await store.connect() }; defer { reconnect.cancel() }
            try await until { await transport.waiting("GET", self.sync) }
            XCTAssertEqual(store.pendingMessage?.id, queued.id)
            let beforeValidation = await transport.commands
            XCTAssertTrue(beforeValidation.isEmpty)
            await transport.release("GET", sync)
            await reconnect.value
            try await until { await transport.waiting("POST", path) }
            XCTAssertNil(store.pendingMessage)
            var rows = TranscriptItem.project(store.displaySnapshot)
            XCTAssertEqual(rows.map(\.id), [queued.rowID])
            XCTAssertFalse(rows[0].isQueued, "Dispatch, not acknowledgement, makes the same bubble opaque")
            XCTAssertFalse(store.canStop, "No actual operation is known before the acknowledgement")
            await transport.hold("GET", sync)
            await transport.release("POST", path)
            try await until { await transport.waiting("GET", self.sync) }
            XCTAssertTrue(store.canStop)
            XCTAssertTrue(store.awaitingSendSnapshot)
            XCTAssertEqual(TranscriptItem.project(store.displaySnapshot).map(\.id), [queued.rowID])
            // A still-open menu from the accepted row must not touch a dependent queue.
            store.connected = false
            store.drafts["session"] = "Dependent"
            await store.send()
            let next = try XCTUnwrap(store.pendingMessage)
            store.cancelPendingMessage(rowID: queued.rowID)
            XCTAssertEqual(store.pendingMessage?.id, next.id)
            store.cancelPendingMessage(rowID: next.rowID)
            store.connected = true
            var acknowledged = snapshot(operation: steering ? "original" : "sent-operation")
            if case .object(var fields) = acknowledged {
                fields["messages"] = .array([.object(["id": .string("sent-message"), "role": .string("user"),
                                                     "text": .string(queued.text)])])
                acknowledged = .object(fields)
            }
            await transport.setSnapshot(acknowledged)
            await transport.release("GET", sync)
            await store.poll()
            try await until { !store.awaitingSendSnapshot }
            rows = TranscriptItem.project(store.displaySnapshot)
            XCTAssertEqual(rows.map(\.id), [queued.rowID])
            XCTAssertFalse(rows[0].isQueued)
            XCTAssertEqual(store.snapshot["messages"].array.first?["id"].string, "sent-message")
            let commands = await transport.commands
            XCTAssertEqual(commands.map(\.path), [path], "Reads and reconnect must never replay a mutation")
            XCTAssertEqual(commands[0].body?["text"].string, queued.text)
            if steering { XCTAssertEqual(commands[0].body?["operationID"].string, "original") }
        }
    }

    func testRejectedQueueValidationRestoresColdDraftWithoutHiddenRow() async throws {
        let transport = ActionReadinessTransport(), store = try makeStore(transport)
        await store.connect()
        store.selected = "session" // Authenticated, but no session snapshot yet.
        var presentation = ConversationPresentation(conversationID: "session", catalog: store.conversations, snapshot: store.displaySnapshot)
        await transport.failNext("GET", sync, disconnect: false)
        store.drafts["session"] = "Not verified"
        await store.send()
        try await until { store.pendingMessage == nil }
        presentation.update(store.displaySnapshot)
        XCTAssertEqual(store.drafts["session"], "Not verified")
        XCTAssertEqual(presentation.snapshot, .null)
        XCTAssertTrue(TranscriptItem.project(presentation.snapshot).isEmpty)
        XCTAssertFalse(store.awaitingSendSnapshot)
        await store.poll()
        let commands = await transport.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testNavigationAndSuspensionCancelBufferWithoutRetargeting() async throws {
        for destination in ["other", "all", "suspend"] {
            let transport = ActionReadinessTransport(), store = try makeStore(transport)
            await transport.setFailConnections(true)
            store.selected = "session"
            store.drafts["session"] = "Original session input"
            store.drafts["other"] = "Other session draft"
            await store.send()
            XCTAssertNotNil(store.pendingMessage)
            store.drafts["session"] = "Newer"
            switch destination {
            case "other": store.selected = "other"
            case "all": store.selected = nil
            default: await store.suspend()
            }
            XCTAssertNil(store.pendingMessage, destination)
            XCTAssertEqual(store.drafts["session"], "Original session input\n\nNewer", destination)
            XCTAssertEqual(store.drafts["other"], "Other session draft", destination)
            await transport.setFailConnections(false)
            await store.poll()
            let commands = await transport.commands
            XCTAssertTrue(commands.isEmpty, "Recovery must not send the cancelled buffer to \(destination)")
        }
    }

    func testReconnectRevalidatesOriginalOperationAndNeverFallsBackToAnotherTurn() async throws {
        let cases: [(name: String, observed: RemoteJSON?, authoritative: RemoteJSON, command: String?)] = [
            ("same operation", snapshot(operation: "original"), snapshot(operation: "original"), steer),
            ("completed operation", snapshot(operation: "original"), snapshot(operation: "original", state: "completed"), nil),
            ("replacement operation", snapshot(operation: "original"), snapshot(operation: "replacement"), nil),
            ("cancelling operation", snapshot(operation: "original"), snapshot(operation: "original", state: "cancelling"), nil),
            ("cold idle session", nil, snapshot(), turns),
            ("unknown intent must not bind a new operation", nil, snapshot(operation: "unobserved"), nil)
        ]
        for value in cases {
            let transport = ActionReadinessTransport(), store = try makeStore(transport)
            if let observed = value.observed {
                await ready(store, transport, snapshot: observed)
                await transport.disconnect()
                await transport.setFailConnections(true)
                await store.poll()
            } else {
                await transport.setFailConnections(true)
                store.selected = "session"
            }
            store.drafts["session"] = "Follow up"
            XCTAssertTrue(store.canSend, value.name)
            await store.send()
            XCTAssertNotNil(store.pendingMessage, value.name)
            await transport.setSnapshot(value.authoritative)
            await transport.setFailConnections(false)
            await transport.hold("GET", sync)
            let reconnecting = Task { await store.connect() }; defer { reconnecting.cancel() }
            try await until { await transport.waiting("GET", self.sync) }
            let beforeValidation = await transport.commands
            XCTAssertTrue(beforeValidation.isEmpty, value.name)
            await transport.release("GET", sync)
            await reconnecting.value
            try await until {
                let commands = await transport.commands
                return store.pendingMessage == nil && commands.count == (value.command == nil ? 0 : 1)
            }
            await store.poll() // A later authoritative read must not replay a rejected buffer either.
            let commands = await transport.commands
            XCTAssertEqual(commands.map(\.path), value.command.map { [$0] } ?? [], value.name)
            if value.command == steer {
                XCTAssertEqual(commands.first?.body?["operationID"].string, "original")
            }
            if value.command != nil {
                XCTAssertEqual(commands.first?.body?["text"].string, "Follow up")
                XCTAssertEqual(store.drafts["session"], "", value.name)
            } else {
                XCTAssertEqual(store.drafts["session"], "Follow up", value.name)
            }
        }
    }

    func testColdCatalogOperationCannotBeReboundAfterItSettles() async throws {
        let transport = ActionReadinessTransport(), store = try makeStore(transport)
        store.conversations = [snapshot(operation: "catalog-operation")]
        store.selected = "session"
        store.drafts["session"] = "Bound to the catalog operation"
        await store.send()
        XCTAssertNotNil(store.pendingMessage)
        await transport.setSnapshot(snapshot(operation: "catalog-operation", state: "completed"))
        await store.connect()
        try await until { store.pendingMessage == nil }
        let commands = await transport.commands
        XCTAssertTrue(commands.isEmpty, "A cold cached operation must never become a new turn")
        XCTAssertEqual(store.drafts["session"], "Bound to the catalog operation")
    }

    func testBufferedFollowupDrainsAfterSendAcknowledgementWithoutHoldingReadbackLock() async throws {
        let transport = ActionReadinessTransport(), store = try makeStore(transport)
        await ready(store, transport)
        await transport.hold("POST", turns)
        store.drafts["session"] = "First"
        let first = Task { await store.send() }; defer { first.cancel() }
        try await until { await transport.waiting("POST", self.turns) }
        store.drafts["session"] = "Second"
        XCTAssertTrue(store.canSend, "An in-flight send can have one dependent buffered message")
        await store.send()
        XCTAssertEqual(store.pendingMessage?.text, "Second")
        store.drafts["session"] = "Newest"
        XCTAssertFalse(store.canSend)
        await transport.setSnapshot(snapshot(operation: "sent-operation"))
        await transport.hold("GET", sync)
        await transport.release("POST", turns)
        try await until { await transport.waiting("GET", self.sync) }
        XCTAssertFalse(store.hasPendingCommands, "Readback must release the acknowledged send's command lock")
        let beforeValidation = await transport.commands
        XCTAssertEqual(beforeValidation.map(\.path), [turns])
        await transport.release("GET", sync)
        await first.value
        try await until {
            let dispatched = await transport.commands.contains { $0.path == self.steer }
            return dispatched && store.pendingMessage == nil && !store.hasPendingCommands
        }
        let commands = await transport.commands
        XCTAssertEqual(commands.map(\.path), [turns, steer])
        XCTAssertEqual(commands.last?.body?["operationID"].string, "sent-operation")
        XCTAssertEqual(commands.last?.body?["text"].string, "Second")
        XCTAssertEqual(store.drafts["session"], "Newest")
        XCTAssertNil(store.pendingMessage)
    }

    func testDefiniteSendFailuresRestoreDraftsAndRemainEditableWithoutARevisionOrRead() async throws {
        let cases: [(RemoteFailure.Kind, String)] = [
            (.notDispatched, "The request is too large."), (.rejected, "The operation is no longer active.")
        ]
        for (kind, message) in cases {
            let transport = ActionReadinessTransport(), store = try makeStore(transport)
            await ready(store, transport)
            let before = await transport.requests.count
            await transport.hold("POST", turns)
            await transport.failNext("POST", turns, disconnect: false, kind: kind, message: message)
            store.drafts["session"] = "First"
            let send = Task { await store.send() }; defer { send.cancel() }
            try await until { await transport.waiting("POST", self.turns) }
            store.drafts["session"] = "Dependent"
            await store.send()
            store.drafts["session"] = "Newest"
            await transport.release("POST", turns)
            await send.value
            XCTAssertTrue(store.canSend, "Definite failures must not wait for an unrelated revision")
            XCTAssertFalse(store.awaitingSendSnapshot)
            XCTAssertNil(store.pendingMessage)
            XCTAssertEqual(store.drafts["session"], "First\n\nDependent\n\nNewest")
            XCTAssertTrue(store.visibleError?.contains(message) == true)
            XCTAssertTrue(store.visibleError?.contains("back in the draft") == true)
            XCTAssertFalse(store.visibleError?.contains("could not be confirmed") == true)
            let attempts = await Array(transport.requests.dropFirst(before))
            XCTAssertEqual(attempts.map(\.key), ["POST " + turns], "No read is needed to establish definite rejection")
            await store.poll()
            let commands = await transport.commands
            XCTAssertEqual(commands.map(\.path), [turns], "Recovery must never replay a rejected command")
        }
    }

    func testUncertainHealthySendPerformsOneReadWithoutWaitingForRevisionOrReplaying() async throws {
        let transport = ActionReadinessTransport(), store = try makeStore(transport)
        await ready(store, transport)
        let before = await transport.requests.count
        // An unclassified error remains uncertain even when the socket stays open.
        await transport.failNext("POST", turns, disconnect: false, message: "Acknowledgement lost.")
        await transport.hold("GET", sync)
        store.drafts["session"] = "Possibly delivered"
        let send = Task { await store.send() }; defer { send.cancel() }
        try await until { await transport.waiting("GET", self.sync) }
        XCTAssertFalse(store.canSend)
        XCTAssertFalse(store.hasPendingCommands)
        XCTAssertTrue(store.visibleError?.contains("Message delivery could not be confirmed") == true)
        XCTAssertTrue(store.visibleError?.contains("Acknowledgement lost.") == true)
        var canonical = snapshot(operation: "possibly-accepted", state: "completed")
        if case .object(var fields) = canonical {
            fields["messages"] = .array([.object(["id": .string("accepted"), "role": .string("user"), "text": .string("Possibly delivered")])])
            canonical = .object(fields)
        }
        await transport.setSnapshot(canonical)
        await transport.release("GET", sync)
        await send.value
        XCTAssertTrue(store.canSend, "One authoritative read must unblock even without a change stream/revision")
        XCTAssertEqual(store.snapshot, canonical)
        XCTAssertEqual(store.drafts["session"], "Possibly delivered")
        XCTAssertNotNil(store.visibleError, "The user still needs to inspect delivery before resubmitting the restored draft")
        let attempts = await Array(transport.requests.dropFirst(before))
        XCTAssertEqual(attempts.map(\.key), ["POST " + turns, "GET " + sync])
    }

    func testUncertainPrecedingSendRestoresDependentBufferAndNeverReplays() async throws {
        let transport = ActionReadinessTransport(), store = try makeStore(transport)
        await ready(store, transport)
        await transport.hold("POST", turns)
        await transport.failNext("POST", turns)
        store.drafts["session"] = "First"
        let first = Task { await store.send() }; defer { first.cancel() }
        try await until { await transport.waiting("POST", self.turns) }
        store.drafts["session"] = "Second"
        await store.send()
        XCTAssertEqual(store.pendingMessage?.text, "Second")
        store.drafts["session"] = "Newest"
        await transport.release("POST", turns)
        await first.value
        await store.poll(reconnect: false)
        XCTAssertFalse(store.connected)
        XCTAssertNil(store.pendingMessage)
        XCTAssertEqual(store.drafts["session"], "First\n\nSecond\n\nNewest")
        XCTAssertFalse(store.canSend, "An uncertain request stays blocked until an authoritative read")
        XCTAssertNotNil(store.visibleError, "A failed action remains distinct from a connection-only failure")
        let deliveryWarning = store.visibleError
        await transport.setFailConnections(true)
        await store.connect()
        XCTAssertEqual(store.visibleError, deliveryWarning, "A failed reconnect must not hide uncertain delivery")
        await transport.setFailConnections(false)
        await transport.hold("GET", sync)
        let reconnecting = Task { await store.connect() }; defer { reconnecting.cancel() }
        try await until { await transport.waiting("GET", self.sync) }
        XCTAssertFalse(store.canSend, "Handshake alone cannot resolve an uncertain command")
        await transport.release("GET", sync)
        await reconnecting.value
        await store.poll()
        XCTAssertTrue(store.canSend)
        XCTAssertEqual(store.drafts["session"], "First\n\nSecond\n\nNewest")
        let commands = await transport.commands
        XCTAssertEqual(commands.map(\.path), [turns])
        XCTAssertEqual(commands.first?.body?["text"].string, "First")
    }

    func testExpiryRestoresBeforeNewerDraftWithoutDispatchOrChangingErrors() async throws {
        let cases: [(error: String?, connectionFailure: Bool)] = [
            (nil, false), ("An unrelated action failed.", false), (nil, true)
        ]
        for value in cases {
            let transport = ActionReadinessTransport(), clock = ActionBufferClock()
            let store = try makeStore(transport, clock: clock)
            await transport.setFailConnections(true)
            if value.connectionFailure { await store.poll() }
            else { store.error = value.error }
            let previousError = store.error, previousVisibleError = store.visibleError
            store.selected = "session"
            store.drafts["session"] = "Expired input"
            await store.send()
            XCTAssertNotNil(store.pendingMessage)
            try await until { await clock.waiting }
            store.drafts["session"] = "Newer"
            await clock.advance()
            try await until { store.pendingMessage == nil }
            XCTAssertEqual(store.drafts["session"], "Expired input\n\nNewer")
            XCTAssertEqual(store.error, previousError, "Expiry must not replace or clear an unrelated error")
            XCTAssertEqual(store.visibleError, previousVisibleError, "Expiry must not create a notice or expose a connection-only error")
            await transport.setFailConnections(false)
            await store.poll()
            let commands = await transport.commands
            XCTAssertTrue(commands.isEmpty, "Expired input must not autoplay on the next connection")
        }
    }

    func testApprovalUsesOnlyTheDisplayedTripleAcrossReplacementAndNavigation() async throws {
        let transport = ActionReadinessTransport(), store = try makeStore(transport)
        let original = snapshot(operation: "operation", state: "awaiting_approval", approval: true)
        await ready(store, transport, snapshot: original)
        let displayed = try XCTUnwrap(RemoteStore.ApprovalTarget(snapshot: store.displaySnapshot))
        let replacements: [RemoteJSON] = [
            snapshot(operation: "replacement", state: "awaiting_approval", approval: true),
            .object(["id": .string("session"),
                     "operation": original["operation"],
                     "approval": .object(["id": .string("replacement"), "operationID": .string("operation")])]),
            snapshot(operation: "operation", state: "completed"),
            .object(["id": .string("other"), "operation": original["operation"], "approval": original["approval"]]),
            // An internally inconsistent approval must not authorize a different operation.
            .object(["id": .string("session"), "operation": snapshot(operation: "replacement")["operation"],
                     "approval": original["approval"]])
        ]
        for replacement in replacements {
            store.snapshot = original
            store.selected = "session"
            // This task cannot enter until after the displayed value has changed.
            let tap = Task { await store.approve(displayed, approved: true) }
            store.snapshot = replacement
            await tap.value
        }
        store.snapshot = original
        let navigatingTap = Task { await store.approve(displayed, approved: false) }
        store.selected = "other"
        store.snapshot = .object(["id": .string("other"), "operation": original["operation"], "approval": original["approval"]])
        await navigatingTap.value
        let rejectedCommands = await transport.commands
        XCTAssertTrue(rejectedCommands.isEmpty, "Stale approval intent must never be rebound")

        store.selected = "session"; store.snapshot = original
        await store.approve(displayed, approved: false)
        let commands = await transport.commands
        XCTAssertEqual(commands.map(\.path), ["/v1/conversations/session/approvals"])
        XCTAssertEqual(commands.first?.body, .object([
            "approvalID": .string("approval"), "operationID": .string("operation"), "approved": .bool(false)
        ]))
    }

    func testApprovalLockAndCancellingOperationPreventSteering() async throws {
        let transport = ActionReadinessTransport(), store = try makeStore(transport)
        await ready(store, transport, snapshot: snapshot(operation: "operation", state: "awaiting_approval", approval: true))
        store.drafts["session"] = "Do not steer while cancelling"
        XCTAssertTrue(store.canApprove)
        XCTAssertTrue(store.canStop)
        let approvals = "/v1/conversations/session/approvals"
        await transport.hold("POST", approvals)
        let target = try XCTUnwrap(RemoteStore.ApprovalTarget(snapshot: store.displaySnapshot))
        let approving = Task { await store.approve(target, approved: true) }; defer { approving.cancel() }
        try await until { await transport.waiting("POST", approvals) }
        XCTAssertTrue(store.isUpdatingConversation("session"))
        XCTAssertFalse(store.canApprove)
        XCTAssertFalse(store.canStop)
        await transport.release("POST", approvals)
        await approving.value
        await transport.setSnapshot(snapshot(operation: "operation", state: "cancelling", approval: true))
        await store.poll()
        XCTAssertFalse(store.canSend)
        XCTAssertFalse(store.canStop)
        XCTAssertFalse(store.canApprove)
        await store.send(); await store.stop(); await store.approve(target, approved: true)
        XCTAssertNil(store.pendingMessage)
        XCTAssertEqual(store.drafts["session"], "Do not steer while cancelling")
        let commands = await transport.commands
        XCTAssertEqual(commands.map(\.path), [approvals])
    }
}
