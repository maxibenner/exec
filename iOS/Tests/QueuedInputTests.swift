import XCTest
import CryptoKit
import ExecRemote
@testable import ExecRemoteStore

/// Reuse the command recorder and its independent gates, with cancel-input replies.
private struct QueuedInputTransport: RemoteTransport {
    let base = ActionReadinessTransport()
    let sentID = "cb29cd8e-85ae-4d0d-af25-fae5765ba142"
    var cancelFailure: RemoteFailure? = nil
    var isConnected: Bool { get async { await base.isConnected } }
    func connect(_ host: PairedHost) async throws { try await base.connect(host) }
    func disconnect() async { await base.disconnect() }
    func request(_ method: String, _ path: String, body: RemoteJSON?) async throws -> RemoteJSON {
        let value = try await base.request(method, path, body: body)
        if path.hasSuffix("/steer") {
            return .object(["operationID": value["operationID"], "messageID": .string(sentID)])
        }
        if path.hasSuffix("/cancel-input") {
            if let cancelFailure { throw cancelFailure }
            return .object(["messageID": body?["messageID"] ?? .null])
        }
        return value
    }
}

@MainActor final class QueuedInputTests: XCTestCase {
    private let id = "session"
    private let operation = "9c563bfe-e75b-4798-a825-ce44cef4d40a"
    private let existingID = "86a6e173-c796-448f-9fdf-1b6126ffca5e"
    private let sync = "/v1/conversations/session/sync"
    private let steer = "/v1/conversations/session/steer"
    private let cancel = "/v1/conversations/session/cancel-input"

    private func makeStore(_ transport: QueuedInputTransport) throws -> RemoteStore {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let invitation = try RemoteJSON.object([
            "version": .number(1), "relay": .string("wss://example.invalid"),
            "route": .string(String(repeating: "a", count: 64)), "hostKey": .string(key),
            "expires": .number(0), "localDevelopment": .bool(false)
        ]).decoded(PairingInvitation.self)
        let host = PairedHost(invitation: invitation, deviceName: "Queued input fixture")
        addTeardownBlock { await transport.base.releaseAll() }
        return RemoteStore(client: transport, loadHost: { host }, saveHost: { _ in }, forgetHost: {})
    }

    private func snapshot(pending: [String], committed: [String] = [], state: String = "awaiting_approval") -> RemoteJSON {
        func rows(_ ids: [String]) -> RemoteJSON {
            .array(ids.map { .object(["id": .string($0), "role": .string("user"), "text": .string("Same text")]) })
        }
        return .object([
            "id": .string(id), "messages": rows(committed), "pendingInput": rows(pending),
            "operation": .object(["id": .string(operation), "state": .string(state)]),
            "approval": state == "awaiting_approval"
                ? .object(["id": .string("approval"), "operationID": .string(operation)]) : .null
        ])
    }

    private func untilWaiting(_ transport: QueuedInputTransport, _ method: String, _ path: String) async throws {
        for _ in 0..<10_000 {
            if await transport.base.waiting(method, path) { return }
            await Task.yield()
        }
        throw RemoteFailure("Missing held request: \(method) \(path)")
    }

    func testProjectsAllQueueSourcesAndCancelsTheExactLocalOrCanonicalRow() async throws {
        let transport = QueuedInputTransport(), store = try makeStore(transport)
        await transport.base.setSnapshot(snapshot(pending: [existingID, existingID]))
        await store.connect()
        await store.open(id).value
        let approval = try XCTUnwrap(RemoteStore.ApprovalTarget(snapshot: store.snapshot))
        await transport.base.hold("POST", steer)
        store.drafts[id] = "Same text"
        let sending = try XCTUnwrap(store.beginSend())
        try await untilWaiting(transport, "POST", steer)
        let inFlight = try XCTUnwrap(store.queuedMessages(for: id).last?.id)
        store.drafts[id] = "Unsent"
        XCTAssertNil(store.beginSend())
        let local = try XCTUnwrap(store.pendingMessage?.rowID)
        XCTAssertEqual(store.queuedMessages(for: id).map(\.id), [existingID, inFlight, local])
        XCTAssertTrue(store.queuedMessages(for: "other").isEmpty)
        XCTAssertTrue(store.canCancelQueuedMessage(rowID: local, conversationID: id))
        XCTAssertFalse(store.canCancelQueuedMessage(rowID: inFlight, conversationID: id))
        await store.cancelQueuedMessage(rowID: inFlight, conversationID: id)
        await store.cancelQueuedMessage(rowID: local, conversationID: "other")
        XCTAssertEqual(store.pendingMessage?.rowID, local)
        store.drafts[id] = "New edit"
        await store.cancelQueuedMessage(rowID: local, conversationID: id)
        XCTAssertNil(store.pendingMessage)
        XCTAssertEqual(store.drafts[id], "Unsent\n\nNew edit")

        await transport.base.hold("GET", sync)
        await transport.base.release("POST", steer)
        try await untilWaiting(transport, "GET", sync)
        XCTAssertFalse(store.canCancelQueuedMessage(rowID: inFlight, conversationID: id))
        await transport.base.setSnapshot(snapshot(pending: [existingID, transport.sentID]))
        await transport.base.release("GET", sync)
        await sending.value
        XCTAssertEqual(store.queuedMessages(for: id).map(\.id), [existingID, inFlight])
        XCTAssertTrue(store.canCancelQueuedMessage(rowID: inFlight, conversationID: id))

        await transport.base.hold("POST", cancel)
        let cancelling = Task { await store.cancelQueuedMessage(rowID: inFlight, conversationID: id) }
        try await untilWaiting(transport, "POST", cancel)
        XCTAssertEqual(store.queuedMessages(for: id).map(\.id), [existingID, inFlight])
        await transport.base.setSnapshot(snapshot(pending: [existingID]))
        await transport.base.release("POST", cancel)
        await cancelling.value
        XCTAssertEqual(store.queuedMessages(for: id).map(\.id), [existingID])
        XCTAssertTrue(store.canApprove(approval))
        XCTAssertTrue(store.canStop)
        XCTAssertEqual(store.drafts[id], "Unsent\n\nNew edit")
        await store.cancelQueuedMessage(rowID: inFlight, conversationID: id) // Stale menu.
        let commands = await transport.base.commands
        XCTAssertEqual(commands.map(\.path), [steer, cancel])
        XCTAssertEqual(commands.last?.body, .object(["operationID": .string(operation), "messageID": .string(transport.sentID)]))
    }

    func testStaleAndUnconfirmedCancellationOnlyReadBackTheHostState() async throws {
        for failure in [RemoteFailure("No longer pending.", kind: .rejected, statusCode: 409), RemoteFailure("Lost reply.")] {
            let transport = QueuedInputTransport(cancelFailure: failure), store = try makeStore(transport)
            await transport.base.setSnapshot(snapshot(pending: [existingID], state: "interrupted"))
            await store.connect()
            await store.open(id).value
            XCTAssertTrue(store.canCancelQueuedMessage(rowID: existingID, conversationID: id))
            await transport.base.hold("POST", cancel)
            let cancelling = Task { await store.cancelQueuedMessage(rowID: existingID, conversationID: id) }
            try await untilWaiting(transport, "POST", cancel)
            await transport.base.setSnapshot(snapshot(pending: [], committed: [existingID], state: "interrupted"))
            await transport.base.release("POST", cancel)
            await cancelling.value
            XCTAssertTrue(store.queuedMessages(for: id).isEmpty)
            XCTAssertEqual(store.snapshot["messages"].array.map(\.id), [existingID])
            XCTAssertNil(store.drafts[id])
            XCTAssertEqual(store.error == nil, failure.statusCode == 409)
            let requests = await transport.base.requests
            XCTAssertEqual(requests.suffix(2).map(\.key), ["POST \(cancel)", "GET \(sync)"])
            XCTAssertEqual(requests.filter { $0.method != "GET" }.count, 1)
        }
    }
}
