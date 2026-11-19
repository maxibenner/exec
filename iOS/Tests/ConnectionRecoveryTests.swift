import XCTest
import CryptoKit
import ExecRemote
@testable import ExecRemoteStore

actor FakeTransport: RemoteTransport {
    var isConnected = false
    var connectionAttempts = 0
    var failConnections = false
    var requests: [String] = []
    var conversation: RemoteJSON = .object(["id": .string("session"), "messages": .array([])])
    private var failures: [String: (disconnect: Bool, cancelled: Bool)] = [:]
    private var holdConnection = false
    private var connectionWaiter: CheckedContinuation<Void, Never>?
    private var heldRequest: String?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var captureHeldResponse = false
    var supportsChanges = false
    var subscriptionFailure: String?
    var subscriptionAttempts = 0
    var notice = RemoteChangeNotification(epoch: "epoch", catalog: "catalog", conversations: ["session": "1"])
    private var notices: AsyncThrowingStream<RemoteChangeNotification, Error>.Continuation?
    func enableChanges() { supportsChanges = true }
    func rejectChanges(_ reason: String?) { subscriptionFailure = reason }
    func emit(_ value: RemoteChangeNotification) { notice = value; notices?.yield(value) }
    var duplicateSubscriptions = 0
    var disconnections = 0
    private var holdSubscription = false
    private var subscriptionWaiter: CheckedContinuation<Void, Never>?
    private var holdTeardown = false
    private var teardownWaiter: CheckedContinuation<Void, Never>?
    var waitingForSubscription: Bool { subscriptionWaiter != nil }
    var waitingForTeardown: Bool { teardownWaiter != nil }
    func holdNextSubscription() { holdSubscription = true }
    func releaseSubscription() { subscriptionWaiter?.resume(); subscriptionWaiter = nil }
    func holdNextTeardown() { holdTeardown = true }
    func releaseTeardown() { teardownWaiter?.resume(); teardownWaiter = nil }
    func changes() async throws -> AsyncThrowingStream<RemoteChangeNotification, Error>? {
        subscriptionAttempts += 1
        if let subscriptionFailure { throw RemoteFailure(subscriptionFailure) }
        guard supportsChanges else { return nil }
        guard notices == nil else {
            duplicateSubscriptions += 1
            throw RemoteFailure("Changes are already being observed.")
        }
        let (stream, continuation) = AsyncThrowingStream<RemoteChangeNotification, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        notices = continuation
        if holdSubscription {
            holdSubscription = false
            await withCheckedContinuation { subscriptionWaiter = $0 }
            try Task.checkCancellation()
        }
        continuation.yield(notice)
        return stream
    }
    func stopChanges() async {
        if holdTeardown {
            holdTeardown = false
            await withCheckedContinuation { teardownWaiter = $0 }
        }
        endChanges()
    }
    func endChanges() { notices?.finish(); notices = nil }
    var sessions: [RemoteJSON] = [.object(["id": .string("session")])]
    func setSessions(_ value: [RemoteJSON]) { sessions = value }
    var resetNextSync = false
    var waitingForConnection: Bool { connectionWaiter != nil }
    var waitingForRequest: Bool { requestWaiter != nil }
    func holdNextRequest(_ method: String, _ path: String, captureResponse: Bool = false) {
        heldRequest = method + " " + path; captureHeldResponse = captureResponse
    }
    func releaseRequest() { requestWaiter?.resume(); requestWaiter = nil }

    func connect(_ host: PairedHost) async throws {
        connectionAttempts += 1
        if holdConnection {
            holdConnection = false
            await withCheckedContinuation { connectionWaiter = $0 }
        }
        try Task.checkCancellation()
        if failConnections { throw RemoteFailure("Host unavailable.") }
        isConnected = true
    }
    func disconnect() {
        disconnections += 1
        isConnected = false
        notices?.finish(throwing: RemoteFailure("Disconnected.")); notices = nil
    }
    func failNext(_ method: String, _ path: String, disconnect: Bool = true, cancelled: Bool = false) {
        failures[method + " " + path] = (disconnect, cancelled)
    }
    func setFailConnections(_ value: Bool) { failConnections = value }
    func holdNextConnection() { holdConnection = true }
    func releaseConnection() { connectionWaiter?.resume(); connectionWaiter = nil }
    func setConversation(_ value: RemoteJSON) { conversation = value }
    var snapshots: [String: RemoteJSON] = [:]
    func setSnapshot(_ value: RemoteJSON, for id: String) { snapshots[id] = value }
    func forceReset() { resetNextSync = true }
    private func sync(_ path: String) -> RemoteJSON {
        let id = String(path.split(separator: "/")[2])
        let conversation = snapshots[id] ?? self.conversation
        let messages = conversation["messages"].array
        let query = path.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init)
        let before = query?.hasPrefix("before=") == true
        let anchor = before ? query?.dropFirst("before=".count).description : query?.split(separator: "&").first.map { String($0.dropFirst("after=".count)) }
        let index = anchor.flatMap { id in messages.firstIndex { $0["id"].string == id } }
        let reset = resetNextSync || (query != nil && index == nil) || (!before && index.map { messages.count - $0 > 64 } == true)
        resetNextSync = false
        let end = before && !reset ? index ?? messages.count : messages.count
        let offset = before && !reset ? max(0, end - 64) : (!reset && query != nil ? index ?? 0 : max(0, end - 64))
        var value: [String: RemoteJSON] = [:]
        if case .object(let fields) = conversation { value = fields }
        value["messages"] = .array(Array(messages[offset..<end]))
        return .object(["snapshot": .object(value), "offset": .number(Double(offset)),
                        "total": .number(Double(messages.count)), "reset": .bool(reset || query == nil),
                        "prefix": messages.isEmpty ? .null : .string(String(repeating: "a", count: 64))])
    }
    func request(_ method: String, _ path: String, body: RemoteJSON?) async throws -> RemoteJSON {
        guard isConnected else { throw RemoteFailure("Disconnected.") }
        let key = method + " " + path
        requests.append(key)
        var captured: RemoteJSON?
        if heldRequest == key {
            if captureHeldResponse { captured = response(path) }
            heldRequest = nil
            await withCheckedContinuation { requestWaiter = $0 }
            // Match RelayClient: caller cancellation detaches; it does not close
            // the shared socket or retry the already-dispatched request.
            try Task.checkCancellation()
        }
        if let failure = failures.removeValue(forKey: key) {
            if failure.disconnect { self.disconnect() }
            if failure.cancelled { throw CancellationError() }
            throw RemoteFailure(failure.disconnect ? "Interrupted." : "Request rejected.")
        }
        return captured ?? response(path)
    }
    private func response(_ path: String) -> RemoteJSON {
        switch path {
        case "/v1/models": return .array([])
        case "/v1/conversations": return .array(sessions)
        case let path where path.hasPrefix("/v1/conversations/") && path.contains("/sync"): return sync(path)
        case let path where path.hasSuffix("/turns"):
            return .object(["operationID": .string("sent-operation")])
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

    private func until(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<10_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Transport did not reach the expected state")
        throw RemoteFailure("Test synchronization failed.")
    }

    func testFirstConnectionStaysHiddenWhilePendingAndAfterSuccessOrSuspension() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        XCTAssertFalse(store.showsConnectionFailure)
        await transport.holdNextConnection()
        let connecting = Task { await store.connect() }
        try await until { await transport.waitingForConnection }
        XCTAssertTrue(store.isConnecting)
        XCTAssertFalse(store.connected)
        XCTAssertFalse(store.hasConnectionFailure)
        XCTAssertFalse(store.showsConnectionFailure)
        await transport.releaseConnection(); await connecting.value
        XCTAssertTrue(store.connected)
        XCTAssertFalse(store.hasConnectionFailure)
        await store.suspend()
        XCTAssertFalse(store.connected)
        XCTAssertFalse(store.showsConnectionFailure, "Intentional scene teardown is not a failure.")
        await transport.holdNextConnection()
        let foreground = Task { await store.connect() }
        try await until { await transport.waitingForConnection }
        XCTAssertFalse(store.showsConnectionFailure, "A pending foreground reconnect is not a failure either.")
        await transport.releaseConnection(); await foreground.value
        XCTAssertFalse(store.showsConnectionFailure)
    }

    func testFailureLatchSurvivesRetriesAndActionErrorsUntilRecoveryOrForget() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.setFailConnections(true)
        await store.connect()
        XCTAssertTrue(store.hasConnectionFailure)
        XCTAssertTrue(store.showsConnectionFailure)
        XCTAssertNil(store.visibleError)
        // The connection-error string is cleared at retry admission; its separate
        // presentation state must not disappear or depend on a subsequent toast.
        for actionError in [nil, "Keep the action warning"] as [String?] {
            store.error = actionError
            await transport.holdNextConnection()
            let retry = Task { await store.connect() }
            try await until { await transport.waitingForConnection }
            XCTAssertTrue(store.showsConnectionFailure)
            XCTAssertEqual(store.visibleError, actionError)
            await transport.releaseConnection(); await retry.value
            XCTAssertTrue(store.showsConnectionFailure)
            XCTAssertEqual(store.visibleError, actionError)
        }
        await transport.setFailConnections(false)
        await store.connect()
        XCTAssertTrue(store.connected)
        XCTAssertFalse(store.hasConnectionFailure)
        XCTAssertEqual(store.visibleError, "Keep the action warning")
        await store.suspend()
        XCTAssertFalse(store.showsConnectionFailure, "A recovered failure must not return on suspension.")
        await transport.setFailConnections(true)
        await store.connect()
        XCTAssertTrue(store.showsConnectionFailure)
        await store.forget()
        XCTAssertNil(store.host)
        XCTAssertFalse(store.hasConnectionFailure)
        XCTAssertFalse(store.showsConnectionFailure)
    }

    func testNewHostDoesNotInheritPreviousConnectionFailure() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.setFailConnections(true)
        await store.connect()
        XCTAssertTrue(store.showsConnectionFailure)
        let key = try XCTUnwrap(store.host?.invitation.hostKey)
        let invitation = RemoteJSON.object([
            "version": .number(1), "relay": .string("wss://example.invalid"),
            "route": .string(String(repeating: "b", count: 64)), "hostKey": .string(key),
            "secret": .string(String(repeating: "f", count: 64)),
            "expires": .number(Date().addingTimeInterval(600).timeIntervalSince1970), "localDevelopment": .bool(false)
        ])
        let text = String(decoding: try JSONEncoder().encode(invitation), as: UTF8.self)
        await transport.setFailConnections(false)
        await transport.holdNextConnection()
        let pairing = Task { await store.pair(text) }
        try await until { await transport.waitingForConnection }
        XCTAssertEqual(store.host?.invitation.route, String(repeating: "b", count: 64))
        XCTAssertFalse(store.hasConnectionFailure)
        XCTAssertFalse(store.showsConnectionFailure, "The new host has not failed its first handshake.")
        await transport.releaseConnection(); await pairing.value
        XCTAssertTrue(store.connected)
    }

    func testOfflineFolderBrowseRequiresTheHostWithoutIssuingARequest() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        do {
            _ = try await store.browseFolders(nil, showHidden: false)
            XCTFail("Offline folder browsing must not issue a host request.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Connect to the host first.")
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(store.showsConnectionFailure, "A local admission guard is not a failed connection attempt.")
    }

    func testDisconnectedSettingsDeletionAndFolderFailuresPresentConnectionState() async throws {
        for action in ["settings", "deletion", "folders"] {
            let transport = FakeTransport(), store = try makeStore(transport)
            await store.connect()
            switch action {
            case "settings":
                store.showSettings(); store.settings.prompt = "Preserve the dirty draft"
                await transport.failNext("PATCH", "/v1/library")
                await store.finishSettings()?.value
                XCTAssertEqual(store.settings.prompt, "Preserve the dirty draft")
                XCTAssertNotNil(store.settings.error)
            case "deletion":
                await transport.failNext("DELETE", "/v1/conversations/session")
                await store.deleteConversation("session")
                XCTAssertEqual(store.conversations.map(\.id), ["session"])
                XCTAssertEqual(store.visibleError, "Interrupted.")
            default:
                await transport.failNext("POST", "/v1/workspaces/browse")
                do {
                    _ = try await store.browseFolders(nil, showHidden: false)
                    XCTFail("Expected the interrupted folder read to fail")
                } catch { XCTAssertEqual(error.localizedDescription, "Interrupted.") }
            }
            XCTAssertTrue(store.showsConnectionFailure, action)
            let commands = await transport.requests.filter { !$0.hasPrefix("GET ") }
            XCTAssertEqual(commands.count, 1, "Failure presentation must never dispatch another command.")
        }
    }

    func testCancelledInitialConnectionDoesNotPresentFailure() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.holdNextConnection()
        let connecting = Task { await store.connect() }
        try await until { await transport.waitingForConnection }
        connecting.cancel()
        await transport.releaseConnection(); await connecting.value
        XCTAssertFalse(store.connected)
        XCTAssertFalse(store.hasConnectionFailure)
        XCTAssertNil(store.error)
    }

    func testCancelledAndSupersededReadsDoNotPresentConnectionFailure() async throws {
        for path in ["/v1/conversations", "/v1/conversations/session/sync"] {
            let transport = FakeTransport(), store = try makeStore(transport)
            await store.connect()
            // An explicit cancellation error is not necessarily Task cancellation.
            await transport.failNext("GET", path, disconnect: false, cancelled: true)
            if path.hasSuffix("/sync") { await store.open("session").value }
            else { await store.poll() }
            XCTAssertFalse(store.hasConnectionFailure)
            XCTAssertNil(store.error)

            await transport.holdNextRequest("GET", path)
            let stale = Task {
                if path.hasSuffix("/sync") { await store.open("session").value }
                else { await store.poll() }
            }
            try await until { await transport.waitingForRequest }
            // A newer read supersedes the old ticket, even on the same connection.
            if path.hasSuffix("/sync") { await store.open("session").value }
            else { await store.poll() }
            await transport.failNext("GET", path)
            await transport.releaseRequest(); await stale.value
            XCTAssertFalse(store.hasConnectionFailure, "A superseded read must not publish its late failure.")
            XCTAssertNil(store.error)
        }
    }

    func testTranscriptActivityUpdatesItsListRow() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.poll()
        for state in ["running", "awaiting_approval", "cancelling", "completed"] {
            await transport.setConversation(.object([
                "id": .string("session"), "messages": .array([]),
                "operation": .object(["state": .string(state)])
            ]))
            await store.open("session").value
            XCTAssertEqual(store.conversations.first?["operation"]["state"].string, state)
            XCTAssertEqual(RemoteMessageSubmission.isActive(store.conversations[0]), state != "completed")
        }
    }

    func testLateReadCannotReplaceAnotherSelectedSession() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.setSessions([.object(["id": .string("session")]), .object(["id": .string("other")])])
        await transport.setSnapshot(.object(["id": .string("other"), "messages": .array([])]), for: "other")
        await store.poll()
        await transport.holdNextRequest("GET", "/v1/conversations/session/sync")
        let first = store.open("session")
        while !(await transport.waitingForRequest) { await Task.yield() }
        store.selected = nil
        await store.open("other").value
        XCTAssertEqual(store.snapshot["id"].string, "other")
        await transport.releaseRequest()
        await first.value
        XCTAssertEqual(store.selected, "other")
        XCTAssertEqual(store.snapshot["id"].string, "other")
        await store.open("session").value
        XCTAssertEqual(store.snapshot["id"].string, "session")
        await store.open("other").value
        XCTAssertEqual(store.snapshot["id"].string, "other")
    }

    func testEmptyListIsConfirmedOnlyAfterSuccessfulLoad() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.setSessions([])
        XCTAssertTrue(store.isLoadingConversations)
        XCTAssertFalse(store.hasLoadedConversations)
        await transport.holdNextRequest("GET", "/v1/conversations")
        let loading = Task { await store.poll() }
        while !(await transport.waitingForRequest) { await Task.yield() }
        XCTAssertTrue(store.isLoadingConversations)
        XCTAssertFalse(store.hasLoadedConversations)
        await transport.releaseRequest()
        await loading.value
        XCTAssertTrue(store.hasLoadedConversations)
        XCTAssertFalse(store.isLoadingConversations)
        XCTAssertTrue(store.conversations.isEmpty)
        await store.forget()
        XCTAssertFalse(store.hasLoadedConversations)
    }

    func testFailedInitialListDoesNotConfirmEmptyState() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.failNext("GET", "/v1/conversations")
        await store.poll()
        XCTAssertFalse(store.hasLoadedConversations)
        XCTAssertFalse(store.isLoadingConversations)
        XCTAssertNotNil(store.error)
        await store.poll()
        XCTAssertTrue(store.hasLoadedConversations)
        XCTAssertFalse(store.isLoadingConversations)
        XCTAssertEqual(store.conversations.count, 1)
    }

    func testInterruptedPollingReconnectsAndRefreshesWithoutLosingDraft() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.poll()
        await store.open("session").value
        store.drafts["session"] = "Unsent draft"
        await transport.failNext("GET", "/v1/conversations/session/sync")
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
        XCTAssertFalse(store.hasConnectionFailure, "An action rejection on a healthy channel must not latch a connection failure.")
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
        XCTAssertTrue(store.showsConnectionFailure)
        XCTAssertTrue(store.visibleError?.contains("delivery could not be confirmed") == true)
        await store.poll()
        XCTAssertTrue(store.connected)
        XCTAssertFalse(store.hasConnectionFailure)
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
            XCTAssertTrue(store.showsConnectionFailure, "A lost mutation acknowledgement must also update connection presentation.")
            XCTAssertEqual(store.visibleError, "Interrupted.", "The banner must not consume the action error.")
            await store.poll()
            XCTAssertTrue(store.connected)
            XCTAssertFalse(store.hasConnectionFailure)
            let commands = await transport.requests.filter { !$0.hasPrefix("GET ") }
            XCTAssertEqual(commands, [method + " " + path])
        }
    }

    func testSuspendingInFlightConnectionCannotRestoreConnectedState() async throws {
        for fails in [false, true] {
            let transport = FakeTransport(), store = try makeStore(transport)
            await transport.holdNextConnection()
            let connection = Task { await store.connect() }
            try await until { await transport.waitingForConnection }
            await store.suspend()
            await transport.setFailConnections(fails)
            await transport.releaseConnection(); await connection.value
            XCTAssertFalse(store.connected)
            XCTAssertFalse(store.busy)
            XCTAssertNil(store.error)
            XCTAssertFalse(store.hasConnectionFailure, "Neither late success nor failure may undo intentional suspension.")
            await transport.setFailConnections(false)
            await store.poll() // Next foreground cycle can establish a fresh channel.
            XCTAssertTrue(store.connected)
        }
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
        await transport.holdNextRequest("GET", "/v1/conversations/session/sync")
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

    func testPagedOpenIncrementalPollAndOlderHistory() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        func message(_ index: Int, text: String? = nil) -> RemoteJSON {
            .object(["id": .string("message-\(index)"), "role": .string("assistant"),
                     "text": .string(text ?? "Text \(index)")])
        }
        func conversation(_ messages: [RemoteJSON]) -> RemoteJSON {
            .object(["id": .string("session"), "messages": .array(messages),
                     "operation": .object(["state": .string("running")])])
        }
        let original = (0..<80).map { message($0) }
        await transport.setConversation(conversation(original))
        await store.poll()
        await store.open("session").value
        XCTAssertEqual(store.snapshot["messages"].array.count, 64)
        XCTAssertEqual(store.snapshot["messages"].array.first?["id"].string, "message-16")
        XCTAssertTrue(store.hasEarlierMessages)

        await transport.setConversation(conversation(Array(original.dropLast()) + [message(79, text: "Streaming update"), message(80)]))
        await store.poll()
        XCTAssertEqual(store.snapshot["messages"].array.count, 65)
        XCTAssertEqual(store.snapshot["messages"].array[63]["text"].string, "Streaming update")
        let requests = await transport.requests
        XCTAssertTrue(requests.contains { $0.hasPrefix("GET /v1/conversations/session/sync?after=message-79&prefix=") })

        await store.loadEarlier()
        XCTAssertFalse(store.hasEarlierMessages)
        XCTAssertEqual(store.snapshot["messages"].array.count, 81)
        XCTAssertEqual(store.snapshot["messages"].array.first?["id"].string, "message-0")
        await transport.forceReset()
        await store.poll()
        XCTAssertEqual(store.snapshot["messages"].array.count, 64)
        XCTAssertTrue(store.hasEarlierMessages)
    }

    func testPendingDeletionSurvivesRefreshAndFailureRestoresDraft() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.poll()
        store.drafts["session"] = "Keep this draft"
        await transport.holdNextRequest("DELETE", "/v1/conversations/session")
        await transport.failNext("DELETE", "/v1/conversations/session", disconnect: false)
        let deletion = Task { await store.deleteConversation("session") }
        for _ in 0..<1000 {
            if await transport.waitingForRequest { break }
            await Task.yield()
        }
        let waiting = await transport.waitingForRequest
        XCTAssertTrue(waiting)
        XCTAssertTrue(store.conversations.isEmpty)
        // A stale successful read during the pending DELETE cannot resurrect it.
        try await store.refresh()
        XCTAssertTrue(store.conversations.isEmpty)
        await transport.releaseRequest()
        await deletion.value
        XCTAssertEqual(store.conversations.map(\.id), ["session"])
        XCTAssertEqual(store.drafts["session"], "Keep this draft")
        XCTAssertEqual(store.error, "Request rejected.")
        await store.poll()
        let deletes = await transport.requests.filter { $0.hasPrefix("DELETE ") }
        XCTAssertEqual(deletes.count, 1)
    }

    func testAcceptedDeletionIsNotRestoredByRefreshFailureOrRecovery() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.poll()
        store.drafts["session"] = "Remove only after acceptance"
        await transport.failNext("GET", "/v1/library")
        await store.deleteConversation("session")
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertNil(store.drafts["session"])
        XCTAssertEqual(store.error, "Interrupted.")
        // Reconnection returns the fake's stale list; the tombstone still wins.
        await store.poll()
        XCTAssertTrue(store.connected)
        XCTAssertTrue(store.conversations.isEmpty)
        let deletes = await transport.requests.filter { $0.hasPrefix("DELETE ") }
        XCTAssertEqual(deletes.count, 1)
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
