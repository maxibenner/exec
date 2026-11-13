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
        let transport = ControlledAgentTransport()
        let id = AgentIntegrationTests.conversationID
        let snapshot = try streamingSnapshot()
        try await transport.requests.reply(AgentAPI.path(id), snapshot)
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        try await store.loadSession(id)
        try transport.emit(.object(["type": .string("snapshot"), "snapshot": snapshot]))
        for delta in ["Hello ", "世界", " 👋"] {
            try transport.emit(.object(["type": .string("runtime"), "event": .object([
                "type": .string("text"), "conversationID": .string(id.uuidString),
                "operationID": .string(AgentIntegrationTests.operationID.uuidString),
                "messageID": .string(AgentIntegrationTests.assistantID.uuidString), "delta": .string(delta)])]))
        }
        try await wait { store.messages.last?.text == "Hello 世界 👋" }
        try expect(store.messages.count == 2 && store.messages.last?.status == .streaming)
        // Terminal snapshot replaces provisional text/calls instead of appending another turn.
        try transport.emit(.object(["type": .string("snapshot"), "snapshot": try AgentIntegrationTests.fixture(state: "completed", result: true)]))
        try await wait { !store.busy }
        try expect(store.messages.count == 3 && store.messages[1].text == "Checking…")
        let final = store.messages
        try transport.emit(.object(["type": .string("snapshot"), "snapshot": try AgentIntegrationTests.fixture(state: "completed", result: true)]))
        for _ in 0..<5 { await Task.yield() }
        try expect(store.messages == final)
        transport.channel.continuation.finish(throwing: ExecError("Observer interrupted; work is not cancelled."))
        try await wait { store.error != nil }
        let requests = await transport.requests.requests
        try expect(requests.allSatisfy { !$0.path.hasSuffix("/turns") && !$0.path.hasSuffix("/cancel") })
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
