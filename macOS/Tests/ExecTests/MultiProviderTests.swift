import Foundation

@MainActor private final class RegistryProbe: ChatProvider {
    final class Connection {
        var account: String? = "account"
        var discoveriesFail = false
        var requests: [String] = []
        var inputs: [[Message]] = []
        var definitions: [[String]] = []
        var searches: [String] = []
        var script: [[ChatEvent]] = []
        var onSend: (() -> Void)?
        var restored: [Data] = []
    }
    let displayName: String
    let connectionTitle = "Connect"
    let connection: Connection
    var account: String? { connection.account }
    let supportsWebSearch = true
    var supportsImageGeneration: Bool { displayName == "OpenAI" }
    var supportsCompaction: Bool { displayName == "OpenAI" }
    var state: Data?
    init(_ name: String, connection: Connection = Connection()) { displayName = name; self.connection = connection }
    func makeConversationProvider() throws -> any ChatProvider { RegistryProbe(displayName, connection: connection) }
    func connect() async throws { connection.account = "account" }
    func disconnect() async throws { connection.account = nil }
    func models() async throws -> [ChatModel] {
        if connection.discoveriesFail { throw ExecError("Unavailable") }
        return [ChatModel(id: "model", name: displayName, acceptsImages: supportsImageGeneration)]
    }
    func encodeConversationState() throws -> Data? { state }
    func restoreConversationState(_ data: Data?, history: [Message]) throws {
        state = data
        if let data { connection.restored.append(data) }
    }
    func searchWeb(query: String, model: String, effort: String?) async throws -> WebSearchResult {
        connection.searches.append(model)
        return WebSearchResult(query: query, answer: "Found", sources: [])
    }
    func send(_ messages: [Message], model: String, effort: String?, instructions: String, tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error> {
        connection.requests.append(model)
        connection.inputs.append(messages)
        connection.definitions.append(tools.map(\.name))
        connection.onSend?()
        state = Data(displayName.utf8)
        let events = connection.script.isEmpty ? [.text(displayName), .completed] : connection.script.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

@MainActor struct MultiProviderTests {
    private func registry(_ openAI: RegistryProbe, _ deepSeek: RegistryProbe) -> ProviderRegistry {
        ProviderRegistry(entries: [.init(id: "openai", provider: openAI), .init(id: "deepseek", provider: deepSeek)], libraryIdentity: "account")
    }

    func switchesProvidersAndRestoresMixedHistory() async throws {
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        let registry = registry(openAI, deepSeek)
        let provider = MultiProvider(registry: registry)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let store = ChatStore(provider: provider, sessions: sessions, newConversation: true)
        store.installModels(try await provider.models(), cached: false)
        for (model, text) in [("model", "First"), ("deepseek/model", "Second"), ("model", "Third")] {
            store.selectedModel = model
            store.draft = text
            store.send()
            await store.waitUntilIdle()
            try expect(store.error == nil)
        }
        try expect(openAI.connection.requests == ["model", "model"] && deepSeek.connection.requests == ["model"])
        try expect(openAI.connection.inputs.last?.contains { $0.text == "DeepSeek" } == true)
        try expect(deepSeek.connection.inputs.last?.contains { $0.text == "OpenAI" } == true)
        try expect(openAI.connection.definitions[0].contains("generate_image"))
        try expect(!deepSeek.connection.definitions[0].contains("generate_image"))
        let id = store.currentSessionID!
        let snapshot = try await sessions.load(id: id)!
        let reopened = ChatStore(provider: MultiProvider(registry: registry), sessions: sessions)
        reopened.installModels(store.models, cached: false)
        try await reopened.loadSession(id)
        try expect(reopened.messages == snapshot.messages && reopened.currentSessionID == id)
        try expect(openAI.connection.restored == [Data("OpenAI".utf8)])
        try expect(deepSeek.connection.restored == [Data("DeepSeek".utf8)])
        reopened.selectedModel = "deepseek/model"
        reopened.draft = "After restart"
        reopened.send()
        await reopened.waitUntilIdle()
        try expect(reopened.error == nil && deepSeek.connection.inputs.last?.contains { $0.text == "Third" } == true)
    }

    func toolsStayWithRunningProviderWhileSelectionChanges() async throws {
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        let provider = MultiProvider(registry: registry(openAI, deepSeek))
        let store = ChatStore(provider: provider, newConversation: true)
        store.installModels(try await provider.models(), cached: false)
        store.selectedModel = "deepseek/model"
        store.searchModel = "model" // A Codex preference must not cross the provider boundary.
        deepSeek.connection.script = [[.toolCall(.init(id: "search", name: "web_search", arguments: #"{"query":"Swift"}"#)), .completed], [.text("Done"), .completed]]
        deepSeek.connection.onSend = { store.selectedModel = "model" }
        defer { deepSeek.connection.onSend = nil }
        store.draft = "Search"
        store.send()
        await store.waitUntilIdle()
        try expect(store.error == nil)
        try expect(deepSeek.connection.requests == ["model", "model"])
        try expect(deepSeek.connection.searches == ["model"] && openAI.connection.searches.isEmpty)
        try expect(deepSeek.connection.definitions.allSatisfy { !$0.contains("generate_image") })
        try expect(openAI.connection.requests.isEmpty && store.selectedModel == "model")
    }

    func independentDisconnectAndPartialCatalogFailure() async throws {
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        let registry = registry(openAI, deepSeek)
        let provider = MultiProvider(registry: registry)
        let models = try await provider.models()
        try expect(models.map(\.id) == ["model", "deepseek/model"])
        openAI.connection.discoveriesFail = true
        let partial = try await provider.models()
        try expect(partial.count == 2)
        try expect(provider.modelDiscoveryWarning?.contains("OpenAI") == true)
        let child = try provider.makeConversationProvider()
        let store = ChatStore(provider: child, newConversation: true)
        store.installModels(models, cached: false)
        store.selectedModel = "model"
        try await provider.disconnect(id: "openai")
        try expect(openAI.account == nil && deepSeek.account != nil && child.account != nil)
        try expect(child.conversationIdentity == "account")
        try expect(!child.isModelAvailable("model") && child.isModelAvailable("deepseek/model"))
        let remaining = try await provider.models()
        try expect(remaining.map(\.id) == ["deepseek/model"])
        store.installModels(remaining, cached: false)
        try expect(store.selectedModel == "model") // No silent cross-provider fallback.
        store.draft = "Keep my chosen provider"
        store.send()
        await store.waitUntilIdle()
        try expect(store.error?.contains("Connect OpenAI") == true && deepSeek.connection.requests.isEmpty)
        try expect(!provider.supportsImageGeneration(model: "deepseek/model") && !provider.supportsCompaction(model: "deepseek/model"))
        for try await _ in child.send([Message(role: .user, text: "Continue")], model: "deepseek/model", effort: nil, instructions: "", tools: []) {}
        try expect(deepSeek.connection.requests == ["model"])
        do {
            for try await _ in child.send([Message(role: .user, text: "No fallback")], model: "model", effort: nil, instructions: "", tools: []) {}
            throw CheckFailure(description: "Expected disconnected provider failure")
        } catch is ExecError {}
        try expect(deepSeek.connection.requests.count == 1)
    }

    func legacyStateAndAccountBoundaries() async throws {
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        let registry = registry(openAI, deepSeek)
        let provider = MultiProvider(registry: registry)
        let legacy = Data(#"{"version":1,"outputs":{}}"#.utf8)
        try provider.restoreConversationState(legacy, history: [])
        try expect(openAI.connection.restored == [legacy] && deepSeek.connection.restored.isEmpty)
        let saved = try provider.encodeConversationState()
        openAI.connection.account = "different-account"
        let reopened = MultiProvider(registry: registry)
        try reopened.restoreConversationState(saved, history: [])
        try expect(openAI.connection.restored == [legacy]) // No opaque state reuse for another account.
        try expectFailure { try reopened.restoreConversationState(Data(#"{"format":"exec.providers.future"}"#.utf8), history: []) }
    }

    func libraryRetainsSessionsAndOtherConnectionOnSignout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "MultiProviderTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let openAI = RegistryProbe("OpenAI"), deepSeek = RegistryProbe("DeepSeek")
        let provider = MultiProvider(registry: registry(openAI, deepSeek))
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root), preferences: preferences)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations && library.models.count == 2 }
        library.selectedModel = "deepseek/model"
        library.draft = "Preserve me"
        library.send()
        try await wait { !library.hasRunningOperations }
        let id = library.currentSessionID
        library.disconnect(providerID: "openai")
        try await wait { !library.hasRunningOperations && library.models.count == 1 }
        try expect(library.currentSessionID == id && library.messages.contains { $0.text == "Preserve me" })
        try expect(library.connections.first?.account == nil && library.connections.last?.account != nil)
        library.disconnect(providerID: "deepseek")
        try await wait { !library.hasRunningOperations }
        try expect(library.account == nil && library.currentSessionID == id && library.sessionList.contains { $0.id == id })
        library.connect(providerID: "deepseek")
        try await wait { !library.hasRunningOperations && library.models.count == 1 }
        try expect(library.currentSessionID == id && library.messages.contains { $0.text == "Preserve me" })
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Provider registry test timed out")
    }
}
