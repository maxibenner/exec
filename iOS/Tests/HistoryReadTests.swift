import XCTest
import CryptoKit
import ExecRemote
@testable import ExecRemoteStore

@MainActor final class HistoryReadTests: XCTestCase {
    private let syncPath = "/v1/conversations/session/sync"

    private func makeStore(_ transport: FakeTransport) throws -> RemoteStore {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let invitation = try JSONDecoder().decode(PairingInvitation.self, from: JSONEncoder().encode(RemoteJSON.object([
            "version": .number(1), "relay": .string("wss://example.invalid"),
            "route": .string(String(repeating: "a", count: 64)), "hostKey": .string(key),
            "expires": .number(0), "localDevelopment": .bool(false)
        ])))
        let host = PairedHost(invitation: invitation, deviceName: "History read fixture")
        return RemoteStore(client: transport, loadHost: { host }, saveHost: { _ in }, forgetHost: {})
    }

    private func snapshot(_ title: String, id: String = "session", messages: [String] = ["m1"]) -> RemoteJSON {
        .object(["id": .string(id), "title": .string(title), "messages": .array(messages.map {
            .object(["id": .string($0), "role": .string("assistant"), "text": .string($0)])
        })])
    }

    private func until(_ predicate: @MainActor () async -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<10_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("History read did not reach the expected state", file: file, line: line)
        throw RemoteFailure("Test synchronization failed.")
    }

    private func historyRequests(_ transport: FakeTransport) async -> [String] {
        await transport.requests.filter { $0.hasPrefix("GET " + syncPath) }
    }

    func testColdOpenRepeatedOpenAndExplicitRefreshShareOneRead() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.setConversation(snapshot("Baseline"))
        await store.connect()
        await transport.holdNextRequest("GET", syncPath, captureResponse: true)
        let first = store.open("session")
        try await until { await transport.waitingForRequest }
        let second = store.open("session")
        var refreshing = false
        let refresh = Task {
            refreshing = true
            try await store.refresh()
        }
        try await until { refreshing }
        let pending = await historyRequests(transport)
        XCTAssertEqual(pending, ["GET " + syncPath])
        await transport.releaseRequest()
        await first.value; await second.value; try await refresh.value
        XCTAssertEqual(store.snapshot["title"].string, "Baseline")
        XCTAssertEqual(store.snapshot["messages"].array.map { $0["id"].string }, ["m1"])
        let completed = await historyRequests(transport)
        XCTAssertEqual(completed, ["GET " + syncPath])
    }

    func testCancellingOneWaiterDoesNotBlockTeardownOrCancelTheSharedRead() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.setConversation(snapshot("Baseline"))
        await store.connect()
        await transport.holdNextRequest("GET", syncPath, captureResponse: true)
        let opening = store.open("session")
        try await until { await transport.waitingForRequest }
        var started = false, finished = false
        let refresh = Task {
            started = true
            // Full refresh intentionally returns quietly on cancellation. It
            // must still detach before the held common history request finishes.
            try? await store.refresh()
            finished = true
        }
        try await until { started }
        refresh.cancel()
        try await until { finished }
        XCTAssertTrue(store.loadingConversations.contains("session"))
        XCTAssertEqual(store.snapshot, .null)
        let reads = await historyRequests(transport)
        XCTAssertEqual(reads, ["GET " + syncPath])
        await transport.releaseRequest(); await opening.value; await refresh.value
        XCTAssertEqual(store.snapshot["title"].string, "Baseline")
        XCTAssertFalse(store.loadingConversations.contains("session"))
    }

    func testNoticePublishesJoinedBaselineBeforeHeldIncrementalFollowup() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.enableChanges()
        await store.connect()
        let initial = RemoteChangeNotification(epoch: "epoch", catalog: "catalog", conversations: ["session": "1"])
        await transport.emit(initial)
        let observer = Task { await store.observe() }
        defer { observer.cancel() }
        try await until { store.lastChangeNotification == initial }

        await transport.setConversation(snapshot("Baseline"))
        await transport.holdNextRequest("GET", syncPath, captureResponse: true)
        let opening = store.open("session")
        try await until { await transport.waitingForRequest }
        let libraries = await transport.requests.filter { $0 == "GET /v1/library" }.count
        let latest = RemoteChangeNotification(epoch: "epoch", catalog: "updated", conversations: ["session": "2"])
        await transport.setConversation(snapshot("Latest", messages: ["m1", "m2"]))
        await transport.emit(latest)
        // The catalog read is a barrier: consume has captured the baseline's ticket.
        try await until { await transport.requests.filter { $0 == "GET /v1/library" }.count > libraries }
        let followupPath = syncPath + "?after=m1&prefix=" + String(repeating: "a", count: 64)
        await transport.holdNextRequest("GET", followupPath, captureResponse: true)
        await transport.releaseRequest()
        try await until { await transport.waitingForRequest }
        await opening.value
        XCTAssertEqual(store.snapshot["title"].string, "Baseline")
        XCTAssertEqual(store.snapshot["messages"].array.map { $0["id"].string }, ["m1"])
        XCTAssertEqual(store.lastChangeNotification, initial, "Do not acknowledge the notice before its follow-up applies")
        let pending = await historyRequests(transport)
        XCTAssertEqual(pending, ["GET " + syncPath, "GET " + followupPath])

        await transport.releaseRequest()
        try await until { store.lastChangeNotification == latest }
        XCTAssertEqual(store.snapshot["title"].string, "Latest")
        XCTAssertEqual(store.snapshot["messages"].array.map { $0["id"].string }, ["m1", "m2"])
        let completed = await historyRequests(transport)
        XCTAssertEqual(completed, pending, "Exactly one incremental catch-up should follow the baseline")
        observer.cancel(); await observer.value
    }

    func testCancelledOpenWarmsCacheWithoutReplacingNewSelection() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.setSessions(["session", "other"].map { .object(["id": .string($0)]) })
        await transport.setConversation(snapshot("Warmed baseline"))
        await transport.setSnapshot(snapshot("Other", id: "other"), for: "other")
        await store.connect()
        await transport.holdNextRequest("GET", syncPath, captureResponse: true)
        let opening = store.open("session")
        try await until { await transport.waitingForRequest }
        opening.cancel()
        await store.open("other").value
        await transport.releaseRequest(); await opening.value
        XCTAssertEqual(store.selected, "other")
        XCTAssertEqual(store.snapshot["title"].string, "Other")

        let followupPath = syncPath + "?after=m1&prefix=" + String(repeating: "a", count: 64)
        await transport.holdNextRequest("GET", followupPath)
        let returning = store.open("session")
        XCTAssertEqual(store.snapshot["title"].string, "Warmed baseline", "Navigation projects the warmed cache synchronously")
        try await until { await transport.waitingForRequest }
        await transport.releaseRequest(); await returning.value
        let reads = await historyRequests(transport)
        XCTAssertEqual(reads, ["GET " + syncPath, "GET " + followupPath])
        XCTAssertNil(store.visibleError)
    }

    func testReconnectRejectsOldSharedReadWithoutReplacingFreshState() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.setConversation(snapshot("Old connection"))
        await store.connect()
        await transport.holdNextRequest("GET", syncPath, captureResponse: true)
        let opening = store.open("session")
        try await until { await transport.waitingForRequest }
        await store.suspend()
        await transport.setConversation(snapshot("Reconnected", messages: ["m2"]))
        await store.connect()
        XCTAssertEqual(store.snapshot["title"].string, "Reconnected")
        await transport.releaseRequest(); await opening.value
        XCTAssertEqual(store.snapshot["title"].string, "Reconnected")
        XCTAssertEqual(store.snapshot["messages"].array.map { $0["id"].string }, ["m2"])
        let reads = await historyRequests(transport)
        XCTAssertEqual(reads, ["GET " + syncPath, "GET " + syncPath])
        XCTAssertNil(store.visibleError)
    }

    func testFailedSharedReadReleasesSlotForLaterExplicitRefresh() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.connect()
        await transport.holdNextRequest("GET", syncPath)
        await transport.failNext("GET", syncPath, disconnect: false)
        let opening = store.open("session")
        try await until { await transport.waitingForRequest }
        var refreshing = false
        let refresh = Task {
            refreshing = true
            try await store.refresh()
        }
        try await until { refreshing }
        await transport.releaseRequest(); await opening.value
        do {
            try await refresh.value
            XCTFail("Both waiters must observe the shared read failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Request rejected.")
        }
        let failed = await historyRequests(transport)
        XCTAssertEqual(failed, ["GET " + syncPath])
        await transport.setConversation(snapshot("Recovered"))
        try await store.refresh()
        XCTAssertEqual(store.snapshot["title"].string, "Recovered")
        let recovered = await historyRequests(transport)
        XCTAssertEqual(recovered, ["GET " + syncPath, "GET " + syncPath])
    }
}
