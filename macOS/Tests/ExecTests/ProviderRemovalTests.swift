import Foundation

private actor ProviderRemovalTransport: AgentTransport {
    private(set) var requests: [FakeAgentTransport.Request] = []
    private var session: AgentJSON = .null
    func installSession(_ snapshot: AgentJSON) { session = snapshot }
    private var connected: Set<String> = ["deepseek", "openai"]
    private var confirmationRequired: Bool
    private var held: CheckedContinuation<Void, Never>?
    private var hold: Bool
    private var fail: Bool
    var removalPending: Bool { held != nil }
    init(confirmationRequired: Bool = true, hold: Bool = false, fail: Bool = false) {
        self.confirmationRequired = confirmationRequired; self.hold = hold; self.fail = fail
    }
    func release() { held?.resume(); held = nil }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        requests.append(.init(method: method, path: path, body: body))
        if method == "DELETE" {
            let input = try JSONDecoder().decode(AgentJSON.self, from: body ?? Data("{}".utf8))
            if confirmationRequired && !input["stopRunning"].bool {
                throw AgentHTTPError(status: 409, message: "Confirmation required", code: "provider_in_use")
            }
            if hold { await withCheckedContinuation { held = $0 } }
            if fail { throw ExecError("Removal acknowledgement lost. Inspect state; not retried.") }
            connected.remove(String(path.split(separator: "/").last!))
        }
        let result: AgentJSON
        if path == "/v1/providers" || method == "DELETE" {
            result = .array(["deepseek", "openai"].map { id in
                .object(["id": .string(id), "name": .string(id == "deepseek" ? "DeepSeek" : "OpenAI"),
                         "connected": .bool(connected.contains(id)), "blocked": .bool(false)])
            })
        } else if path == "/v1/models" {
            result = .array(connected.sorted().map { .object(["id": .string("\($0)/test"), "name": .string($0), "efforts": .array([])]) })
        } else if path == "/v1/conversations" { result = .array(session == .null ? [] : [session]) }
        else if path.contains("/sync") { result = try AgentSyncFixture.page(session, path: path) }
        else if path.hasPrefix("/v1/conversations/") { result = session }
        else if path == "/v1/library" {
            return try JSONEncoder().encode(AgentLibraryConfiguration())
        } else { throw CheckFailure(description: "Unexpected provider-removal request: \(method) \(path)") }
        return try JSONEncoder().encode(result)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        FakeAgentTransport().events(method, path, body: body)
    }
}

@MainActor struct ProviderRemovalTests {
    private func wait(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure(description: "Provider-removal state did not settle")
    }
    private func fixture(_ transport: ProviderRemovalTransport) async throws -> (ChatLibrary, UserDefaults, String) {
        let suite = "exec-provider-removal-\(UUID())"
        // Each fixture owns an isolated preferences suite; no profile, Keychain or live provider.
        let isolated = UserDefaults(suiteName: suite)!
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        try await provider.refreshConnections()
        let library = ChatLibrary(provider: provider, preferences: isolated)
        let snapshot = try AgentIntegrationTests.fixture(state: "running", result: true)
        await transport.installSession(snapshot)
        try library.current.apply(snapshot.decoded(AgentSnapshot.self))
        library.current.draft = "Keep this unsent draft"
        return (library, isolated, suite)
    }
    func confirmationCancellationHasNoEffectsAndDuplicatesAreBounded() async throws {
        let transport = ProviderRemovalTransport()
        let (library, preferences, suite) = try await fixture(transport)
        defer { library.closePresentations(); preferences.removePersistentDomain(forName: suite) }
        let original = library.current.messages
        try expect(library.accountBusy && library.canDisconnectProvider)
        library.settingsTab = .accounts
        library.disconnect(providerID: "deepseek"); library.disconnect(providerID: "deepseek")
        try await wait { !library.authenticating }
        try expect(library.pendingProviderRemoval?.id == "deepseek")
        try expect(library.current.busy && library.current.messages == original && library.canNavigate)
        library.settingsTab = .modelsAndTools; library.settingsTab = .accounts
        library.cancelProviderRemoval()
        try expect(library.pendingProviderRemoval == nil && library.canDisconnectProvider)
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.count == 1 && writes[0].method == "DELETE")
        try expect(try JSONDecoder().decode(AgentJSON.self, from: writes[0].body!)["stopRunning"] == .bool(false))
        try expect(library.connectedProviders.count == 2 && library.current.busy)
        try expect(library.current.draft == "Keep this unsent draft")
    }
    func confirmedRemovalDiscardsOnlyAffectedQueuedWorkAndAllowsModelChange() async throws {
        for fail in [false, true] {
            let transport = ProviderRemovalTransport(hold: true, fail: fail)
            let (library, preferences, suite) = try await fixture(transport)
            defer { library.closePresentations(); preferences.removePersistentDomain(forName: suite) }
            var queuedEffects = 0
            library.current.whenIdle("compact") { queuedEffects += 1 }
            library.disconnect(providerID: "deepseek")
            try await wait { !library.authenticating }
            let id = library.pendingProviderRemoval!.id
            // SwiftUI can dismiss its binding before invoking the captured button action.
            library.cancelProviderRemoval()
            library.confirmProviderRemoval(providerID: id); library.confirmProviderRemoval(providerID: id)
            try await wait { await transport.removalPending }
            try expect(!library.current.canRequestCommands && !library.canDisconnectProvider)
            let interrupted = try AgentIntegrationTests.fixture(state: "interrupted", result: true)
            await transport.installSession(interrupted)
            try library.current.apply(interrupted.decoded(AgentSnapshot.self))
            try expect(queuedEffects == 0 && !library.current.messages.isEmpty)
            await transport.release()
            try await wait { !library.authenticating }
            try expect(library.current.canRequestCommands && queuedEffects == 0)
            try expect((library.connectionError != nil) == fail)
            try expect(library.connectedProviders.contains { $0.id == "deepseek" } == fail)
            try await wait { library.models.contains { $0.id == "openai/test" } }
            library.current.selectedModel = "openai/test"
            try expect(library.current.hasUsableModel)
            try expect(library.current.currentSessionID == AgentIntegrationTests.conversationID)
            try expect(library.current.draft == "Keep this unsent draft")
            let writes = await transport.requests.filter { $0.method != "GET" && $0.path != "/v1/library" }
            try expect(writes.count == 2 && writes.allSatisfy { $0.method == "DELETE" })
            try expect(try JSONDecoder().decode(AgentJSON.self, from: writes[1].body!)["stopRunning"] == .bool(true))
        }
    }
    func unrelatedRunningSessionsDoNotPromptOrStop() async throws {
        let transport = ProviderRemovalTransport(confirmationRequired: false, hold: true)
        let (library, preferences, suite) = try await fixture(transport)
        defer { library.closePresentations(); preferences.removePersistentDomain(forName: suite) }
        library.disconnect(providerID: "openai")
        try await wait { await transport.removalPending }
        try expect(library.pendingProviderRemoval == nil && library.current.canRequestCommands)
        await transport.release()
        try await wait { !library.authenticating }
        try expect(library.pendingProviderRemoval == nil && library.current.busy)
        try expect(library.connectedProviders.map(\.id) == ["deepseek"])
        let writes = await transport.requests.filter { $0.method != "GET" }
        try expect(writes.count == 1 && writes[0].path == "/v1/providers/openai")
    }
}
