import XCTest
import CryptoKit
import ExecRemote
@testable import ExecRemoteStore

private actor FakeTransport: RemoteTransport {
    var isConnected = false
    var connectionAttempts = 0
    var failConnections = false
    var requests: [String] = []
    var conversation: RemoteJSON = .object(["id": .string("session"), "messages": .array([])])
    private var failure: (request: String, disconnect: Bool)?
    private var holdConnection = false
    private var connectionWaiter: CheckedContinuation<Void, Never>?
    private var heldRequest: String?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    var waitingForConnection: Bool { connectionWaiter != nil }
    var waitingForRequest: Bool { requestWaiter != nil }
    func holdNextRequest(_ method: String, _ path: String) { heldRequest = method + " " + path }
    func releaseRequest() { requestWaiter?.resume(); requestWaiter = nil }

    func connect(_ host: PairedHost) async throws {
        connectionAttempts += 1
        if failConnections { throw RemoteFailure("Host unavailable.") }
        isConnected = true
        if holdConnection {
            holdConnection = false
            await withCheckedContinuation { connectionWaiter = $0 }
        }
    }
    func disconnect() { isConnected = false }
    func failNext(_ method: String, _ path: String, disconnect: Bool = true) {
        failure = (method + " " + path, disconnect)
    }
    func setFailConnections(_ value: Bool) { failConnections = value }
    func holdNextConnection() { holdConnection = true }
    func releaseConnection() { connectionWaiter?.resume(); connectionWaiter = nil }
    func setConversation(_ value: RemoteJSON) { conversation = value }
    func request(_ method: String, _ path: String, body: RemoteJSON?) async throws -> RemoteJSON {
        guard isConnected else { throw RemoteFailure("Disconnected.") }
        let key = method + " " + path
        requests.append(key)
        if heldRequest == key {
            heldRequest = nil
            await withCheckedContinuation { requestWaiter = $0 }
            // Match RelayClient: cancelling an in-flight read closes its socket.
            if Task.isCancelled { isConnected = false; throw CancellationError() }
        }
        if failure?.request == key {
            let disconnect = failure!.disconnect
            failure = nil
            if disconnect { isConnected = false }
            throw RemoteFailure(disconnect ? "Interrupted." : "Request rejected.")
        }
        switch path {
        case "/v1/models": return .array([])
        case "/v1/conversations": return .array([.object(["id": .string("session")])])
        case "/v1/conversations/session": return conversation
        default: return .object([:])
        }
    }
}

@MainActor final class ConnectionRecoveryTests: XCTestCase {
    private func makeStore(_ transport: FakeTransport) throws -> RemoteStore {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let invitation = try JSONDecoder().decode(PairingInvitation.self, from: JSONEncoder().encode(RemoteJSON.object([
            "version": .number(1), "relay": .string("wss://example.invalid"),
            "route": .string(String(repeating: "a", count: 64)), "hostKey": .string(key),
            "expires": .number(0), "localDevelopment": .bool(false)
        ])))
        let host = PairedHost(invitation: invitation, deviceName: "Test fixture")
        return RemoteStore(client: transport, loadHost: { host }, saveHost: { _ in }, forgetHost: {})
    }

    func testInterruptedPollingReconnectsAndRefreshesWithoutLosingDraft() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.poll()
        await store.open("session").value
        store.drafts["session"] = "Unsent draft"
        await transport.failNext("GET", "/v1/conversations/session")
        await store.poll()
        XCTAssertFalse(store.connected)
        XCTAssertEqual(store.snapshot["id"].string, "session")

        await transport.setConversation(.object(["id": .string("session"), "title": .string("Fresh snapshot")]))
        await store.poll()
        XCTAssertTrue(store.connected)
        XCTAssertEqual(store.snapshot["title"].string, "Fresh snapshot")
        XCTAssertEqual(store.drafts["session"], "Unsent draft")
        XCTAssertNil(store.error)
        let attempts = await transport.connectionAttempts
        XCTAssertEqual(attempts, 2)
    }

    func testAPIRejectionDoesNotDisconnectHealthyChannel() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.poll()
        await transport.failNext("GET", "/v1/conversations", disconnect: false)
        await store.poll()
        XCTAssertTrue(store.connected)
        XCTAssertEqual(store.error, "Request rejected.")
        await store.poll()
        let attempts = await transport.connectionAttempts
        XCTAssertEqual(attempts, 1)
    }

    func testUncertainSendRestoresDraftButIsNeverReplayedOnRecovery() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.poll()
        await store.open("session").value
        store.drafts["session"] = "Send once"
        await transport.failNext("POST", "/v1/conversations/session/turns")
        await store.send()
        XCTAssertEqual(store.drafts["session"], "Send once")
        await store.poll()
        XCTAssertTrue(store.connected)
        let sends = await transport.requests.filter { $0 == "POST /v1/conversations/session/turns" }
        XCTAssertEqual(sends.count, 1)
    }

    func testMutationsAreNotReplayedDuringRecovery() async throws {
        for (method, path) in [("POST", "/v1/conversations/session/approvals"),
                               ("PATCH", "/v1/library"), ("DELETE", "/v1/conversations/session")] {
            let transport = FakeTransport(), store = try makeStore(transport)
            await store.poll()
            await transport.failNext(method, path)
            await store.mutate(method, path, .object([:]))
            await store.poll()
            XCTAssertTrue(store.connected)
            let commands = await transport.requests.filter { !$0.hasPrefix("GET ") }
            XCTAssertEqual(commands, [method + " " + path])
        }
    }

    func testSuspendingInFlightConnectionCannotRestoreConnectedState() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.holdNextConnection()
        let connection = Task { await store.connect() }
        for _ in 0..<1000 {
            if await transport.waitingForConnection { break }
            await Task.yield()
        }
        let waiting = await transport.waitingForConnection
        XCTAssertTrue(waiting)
        await store.suspend()
        await transport.releaseConnection()
        await connection.value
        XCTAssertFalse(store.connected)
        XCTAssertFalse(store.busy)
        XCTAssertNil(store.error)
        await store.poll() // Next foreground cycle can establish a fresh channel.
        XCTAssertTrue(store.connected)
    }

    func testUnavailableHostBacksOffAndSuccessfulRecoveryResetsDelay() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.setFailConnections(true)
        for expected in [3.0, 6, 12, 24, 30, 30] {
            await store.poll()
            XCTAssertFalse(store.connected)
            XCTAssertFalse(store.busy)
            XCTAssertEqual(store.reconnectDelay, expected)
        }
        await transport.setFailConnections(false)
        await store.poll()
        XCTAssertTrue(store.connected)
        XCTAssertEqual(store.reconnectDelay, 1.5)
    }

    func testReturningToAllSessionsDoesNotCancelSharedConnection() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.poll()
        await transport.holdNextRequest("GET", "/v1/conversations/session")
        let viewTask = Task { await store.open("session").value }
        for _ in 0..<1000 {
            if await transport.waitingForRequest { break }
            await Task.yield()
        }
        let waiting = await transport.waitingForRequest
        XCTAssertTrue(waiting)
        // Simulate the view disappearing while its session snapshot is in flight.
        store.selected = nil
        viewTask.cancel()
        await transport.releaseRequest()
        await viewTask.value
        XCTAssertTrue(store.connected)
        XCTAssertEqual(store.snapshot, .null)
        XCTAssertNil(store.error)
        await store.poll()
        let attempts = await transport.connectionAttempts
        XCTAssertEqual(attempts, 1, "Navigation should not require a new connection")
        store.selected = "session"
        XCTAssertEqual(store.snapshot["id"].string, "session", "The completed read remains cached")
    }

    func testCancelledObserverDoesNotConnect() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        let observer = Task { await store.observe() }
        observer.cancel()
        await observer.value
        let attempts = await transport.connectionAttempts
        XCTAssertEqual(attempts, 0)
    }
}
