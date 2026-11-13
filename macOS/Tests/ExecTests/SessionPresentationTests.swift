import Foundation

private final class SessionEventTransport: AgentTransport, @unchecked Sendable {
    let responses = FakeAgentTransport()
    private let lock = NSLock()
    private var streams: [AsyncThrowingStream<Data, Error>.Continuation] = []
    var streamCount: Int { lock.withLock { streams.count } }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        try await responses.request(method, path, body: body)
    }
    func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { streams.append(continuation) }
        }
    }
    func failLatestStream() {
        let stream = lock.withLock { streams.last }
        stream?.finish(throwing: ExecError("Session no longer exists"))
    }
}

@MainActor struct SessionPresentationTests {
    func newSessionStartsAtTop() throws {
        let suite = "exec-sidebar-order-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: FakeAgentTransport())), preferences: preferences)
        defer { library.closePresentations() }
        let first = try AgentIntegrationTests.fixture(state: "completed", result: true).decoded(AgentSnapshot.self)
        try library.current.apply(first)
        // Activation remembers the old row, but the new create response has not
        // reached its asynchronous catalog checkpoint yet.
        library.newConversation()
        let encoded = String(decoding: try JSONEncoder().encode(AgentIntegrationTests.fixture(state: "completed", result: true)), as: UTF8.self)
        let newID = UUID(uuidString: "ffffffff-1111-4111-8111-111111111111")!
        let data = Data(encoded.replacingOccurrences(of: first.id.uuidString.lowercased(), with: newID.uuidString.lowercased())
            .replacingOccurrences(of: first.id.uuidString, with: newID.uuidString).utf8)
        try library.current.apply(JSONDecoder().decode(AgentSnapshot.self, from: data))
        try expect(library.sidebarSessions.map(\.id) == [newID, first.id])
    }

    func deletionIgnoresStreamClosureAndResumesOnFailure() async throws {
        let transport = SessionEventTransport()
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        let value = try AgentIntegrationTests.fixture(state: "completed", result: true)
        try await transport.responses.reply(AgentAPI.path(AgentIntegrationTests.conversationID), value)
        try await store.loadSession(AgentIntegrationTests.conversationID)
        try expect(transport.streamCount == 1)
        store.beginDeletion()
        transport.failLatestStream()
        for _ in 0..<10 { await Task.yield() }
        try expect(store.error == nil && !store.hasUnsavedChanges)
        store.resumeAfterFailedDeletion()
        try expect(transport.streamCount == 2)
        // A genuine subsequent stream failure must still be surfaced.
        transport.failLatestStream()
        for _ in 0..<100 where store.error == nil { try await Task.sleep(for: .milliseconds(5)) }
        try expect(store.error == "Session no longer exists")
    }
}
