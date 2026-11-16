import AppKit
import Foundation

struct ControlledAgentTransport: AgentTransport {
    let requests = FakeAgentTransport()
    let channel = AsyncThrowingStream<Data, Error>.makeStream()
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        try await requests.request(method, path, body: body)
    }
    func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> { channel.stream }
    func emit(_ value: AgentJSON) throws { channel.continuation.yield(try JSONEncoder().encode(value)) }
}

@MainActor struct AgentEventTests {
    private func wait(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out awaiting frontend state")
    }
    private func streamingSnapshot() throws -> AgentJSON {
        guard case .object(var value) = try AgentIntegrationTests.fixture(state: "running") else { fatalError() }
        value["approval"] = .null
        value["messages"] = .array([
            .object(["id": .string(AgentIntegrationTests.userID.uuidString), "role": .string("user"), "text": .string("Hello")]),
            .object(["id": .string(AgentIntegrationTests.assistantID.uuidString), "role": .string("assistant"), "text": .string(""), "status": .string("streaming"), "calls": .array([])])])
        return .object(value)
    }
    func streamsAndReconcilesWithoutReplacingRenderer() async throws {
        let transport = FakeAgentTransport()
        let id = AgentIntegrationTests.conversationID, path = AgentAPI.path(AgentIntegrationTests.conversationID)
        let initial = try streamingSnapshot()
        try await transport.reply(path, initial)
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        try await store.loadSession(id)
        let messageIDs = store.messages.map(\.id)
        for text in ["Hello ", "Hello 世界", "Hello 世界 👋"] {
            guard case .object(var value) = initial, case .object(var assistant) = initial["messages"].array.last! else {
                throw CheckFailure(description: "Invalid streaming fixture")
            }
            assistant["text"] = .string(text)
            value["messages"] = .array([initial["messages"].array[0], .object(assistant)])
            try await transport.reply(path, .object(value))
            try await wait { store.messages.last?.text == text }
            try expect(store.messages.map(\.id) == messageIDs)
        }
        try await transport.reply(path, AgentIntegrationTests.fixture(state: "completed", result: true))
        try await wait { !store.busy }
        try expect(store.messages.count == 3 && store.messages[1].text == "Checking…")
        let requests = await transport.requests
        try expect(requests.allSatisfy { $0.method == "GET" && $0.path.contains("/sync") })
        try expect(requests.dropFirst().allSatisfy { $0.path.contains("?after=") })
    }
    func reconnectsObserverOnceWithoutReplayingWork() async throws {
        let transport = FakeAgentTransport()
        let id = AgentIntegrationTests.conversationID, path = AgentAPI.path(AgentIntegrationTests.conversationID)
        try await transport.reply(path, streamingSnapshot())
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        try await store.loadSession(id)
        await transport.failNext(path + "/sync")
        for _ in 0..<200 {
            if await transport.requests.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(store.busy && store.error == nil)
        await transport.fail(path + "/sync")
        try await wait { store.error != nil }
        try expect(store.error == "Lost connection to this conversation. Reopen it to reconnect; work may still be running.")
        try expect(store.busy) // A failed read never marks the turn completed or cancels it.
        let requests = await transport.requests
        try expect(requests.count >= 4 && requests.allSatisfy { $0.method == "GET" && $0.path.contains("/sync") })
    }

    func cancellationOwnsCleanupAndUsesExactID() async throws {
        let transport = FakeAgentTransport()
        let id = AgentIntegrationTests.conversationID
        try await transport.reply(AgentAPI.path(id), AgentIntegrationTests.fixture(state: "running"))
        var starts = 0, ends = 0
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)), sleepPrevention: .init(
            begin: { starts += 1; return NSObject() }, end: { _ in ends += 1 }))
        defer { store.closePresentation() }
        try store.apply(AgentIntegrationTests.fixture(state: "running").decoded(AgentSnapshot.self))
        store.stop(); store.stop()
        for _ in 0..<100 {
            if await transport.requests.contains(where: { $0.path.hasSuffix("/cancel") }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(store.busy && store.isStopping && starts == 1 && ends == 0)
        let cancellations = await transport.requests.filter { $0.path.hasSuffix("/cancel") }
        try expect(cancellations.count == 1)
        let body = try JSONDecoder().decode(AgentJSON.self, from: cancellations[0].body!)
        try expect(body["operationID"].string == AgentIntegrationTests.operationID.uuidString.lowercased())
        try await transport.reply(AgentAPI.path(id), AgentIntegrationTests.fixture(state: "interrupted", result: true))
        try await wait { !store.busy }
        try expect(ends == 1)
    }
    func configurationFailureDoesNotRetry() async throws {
        let transport = FakeAgentTransport()
        let id = AgentIntegrationTests.conversationID
        let snapshot = try AgentIntegrationTests.fixture(state: "completed", result: true)
        try await transport.reply(AgentAPI.path(id), snapshot)
        await transport.fail(AgentAPI.path(id, "/settings"))
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        try store.apply(snapshot.decoded(AgentSnapshot.self))
        store.setAutoApproveTools(true)
        await store.waitForPendingSave()
        try expect(store.hasUnsavedChanges)
        // A later snapshot is not permission to retry a failed acknowledgement.
        try store.apply(snapshot.decoded(AgentSnapshot.self))
        store.scheduleSave()
        await store.waitForPendingSave()
        let writes = await transport.requests.filter { $0.path.hasSuffix("/settings") }
        try expect(writes.count == 1 && store.hasUnsavedChanges)
    }
}
