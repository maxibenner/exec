import Foundation

/// One conversation over shared connections. Provider-owned blobs never cross
/// provider/account boundaries; the visible transcript is the portable history.
@MainActor final class MultiProvider: ChatProvider {
    private struct SavedContext: Codable {
        let identity: String?
        let data: Data?
    }
    private struct State: Codable {
        let format: String
        let contexts: [String: SavedContext]
    }
    private let registry: ProviderRegistry
    private var children: [String: any ChatProvider] = [:]
    private var identities: [String: String] = [:]
    private var savedContexts: [String: SavedContext] = [:]
    private var restoredHistory: [Message] = []
    let displayName = "Providers"
    let connectionTitle = "Connect a provider in Settings"
    let retainsLocalConversations = true
    let preservesModelSelection = true
    var conversationIdentity: String? { registry.libraryIdentity }
    var account: String? {
        let names = registry.entries.filter { $0.provider.account != nil }.map { $0.provider.displayName }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }
    var connections: [ProviderConnection] {
        registry.entries.map { entry in
            ProviderConnection(id: entry.id, name: entry.provider.displayName, account: entry.provider.account,
                               authentication: entry.provider.connections[0].authentication)
        }
    }
    var usageProviderName: String { "OpenAI" }
    func recordsAccountUsage(model: String) -> Bool { registry.route(model)?.entry.id == "openai" && isModelAvailable(model) }
    var modelDiscoveryWarning: String? { registry.modelWarning }
    init(registry: ProviderRegistry) { self.registry = registry }
    func makeConversationProvider() throws -> any ChatProvider { MultiProvider(registry: registry) }
    func connect() async throws {
        guard let first = connections.first(where: { $0.authentication == .browser }) else { throw ExecError("Connect a provider in Settings.") }
        try await connect(id: first.id, credential: nil)
    }
    func connect(id: String, credential: String?) async throws { try await registry.connect(id: id, credential: credential) }
    func disconnect() async throws {
        // Account actions must target one provider, never silently sign out all.
        throw ExecError("Choose the provider to disconnect in Settings.")
    }
    func disconnect(id: String) async throws { try await registry.disconnect(id: id) }
    func models() async throws -> [ChatModel] { try await registry.models() }
    func providerID(for model: String) -> String? { registry.route(model)?.entry.id }
    func isModelAvailable(_ model: String) -> Bool { registry.route(model)?.entry.provider.account != nil }

    private func child(_ entry: ProviderRegistry.Entry) throws -> any ChatProvider {
        let identity = entry.provider.conversationIdentity
        if let child = children[entry.id], identities[entry.id] == identity { return child }
        let child = try entry.provider.makeConversationProvider()
        if let saved = savedContexts[entry.id], saved.identity == identity {
            try child.restoreConversationState(saved.data, history: restoredHistory)
        }
        children[entry.id] = child
        identities[entry.id] = identity
        savedContexts[entry.id] = nil
        return child
    }
    private func destination(_ model: String) throws -> (provider: any ChatProvider, model: String) {
        guard let route = registry.route(model), !route.model.isEmpty else { throw ExecError("Unknown model provider.") }
        guard route.entry.provider.account != nil else { throw ExecError("Connect \(route.entry.provider.displayName) in Settings to use this model.") }
        return (try child(route.entry), route.model)
    }
    func clearConversationState() {
        children = [:]; identities = [:]; savedContexts = [:]; restoredHistory = []
    }
    func encodeConversationState() throws -> Data? {
        var contexts = savedContexts
        for entry in registry.entries {
            guard let provider = children[entry.id], identities[entry.id] == entry.provider.conversationIdentity else { continue }
            contexts[entry.id] = SavedContext(identity: identities[entry.id], data: try provider.encodeConversationState())
        }
        return try JSONEncoder().encode(State(format: "exec.providers.v1", contexts: contexts))
    }
    func restoreConversationState(_ data: Data?, history: [Message]) throws {
        clearConversationState()
        restoredHistory = history
        if let data {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["format"] != nil {
                guard let state = try? JSONDecoder().decode(State.self, from: data), state.format == "exec.providers.v1" else {
                    throw ExecError("Saved provider context could not be read.")
                }
                savedContexts = state.contexts
            } else {
                // Sessions saved by the original single-provider app contain raw Codex state.
                savedContexts["openai"] = SavedContext(identity: registry.libraryIdentity, data: data)
            }
        }
        // Validate connected providers now, before ChatStore unlocks the document.
        for entry in registry.entries where entry.provider.account != nil { _ = try child(entry) }
    }

    func supportsWebSearch(model: String) -> Bool { registry.route(model)?.entry.provider.supportsWebSearch == true && isModelAvailable(model) }
    func supportsImageGeneration(model: String) -> Bool { registry.route(model)?.entry.provider.supportsImageGeneration == true && isModelAvailable(model) }
    func supportsCompaction(model: String) -> Bool { registry.route(model)?.entry.provider.supportsCompaction == true && isModelAvailable(model) }
    func usesSearchModel(_ model: String) -> Bool {
        guard let route = registry.route(model), isModelAvailable(model) else { return false }
        return route.entry.provider.usesSearchModel(route.model)
    }
    func searchQueryLimit(model: String) -> Int? {
        guard let route = registry.route(model) else { return nil }
        return route.entry.provider.searchQueryLimit(model: route.model)
    }
    func searchModel(for model: String, preferred: String) -> String {
        // A search preference must never route a tool to a different provider.
        registry.route(model)?.entry.id == registry.route(preferred)?.entry.id ? preferred : model
    }
    func searchWeb(query: String, model: String, effort: String?) async throws -> WebSearchResult {
        let target = try destination(model)
        return try await target.provider.searchWeb(query: query, model: target.model, effort: effort)
    }
    func generateImage(_ request: ImageGenerationTool.Request, model: String) async throws -> ImageAttachment {
        try await destination(model).provider.generateImage(request)
    }
    func accountUsage() async throws -> AccountUsage? {
        // This reports the explicitly labeled Codex subscription, not DeepSeek credits.
        guard let entry = registry.entries.first(where: { $0.id == "openai" }), entry.provider.account != nil else { return nil }
        return try await entry.provider.accountUsage()
    }
    func contextUsage(_ messages: [Message], model: ChatModel, instructions: String, tools: [ToolDefinition]) -> ContextUsage? {
        guard let target = try? destination(model.id) else { return nil }
        let native = nativeModel(model, id: target.model)
        return target.provider.contextUsage(messages, model: native, instructions: instructions, tools: tools)
    }
    private func nativeModel(_ model: ChatModel, id: String) -> ChatModel {
        ChatModel(id: id, name: model.name, contextWindow: model.contextWindow, efforts: model.efforts,
                  defaultEffort: model.defaultEffort, acceptsImages: model.acceptsImages)
    }
    func compact(_ history: [Message], model: ChatModel, instructions: String, tools: [ToolDefinition]) async throws {
        let target = try destination(model.id)
        try await target.provider.compact(history, model: nativeModel(model, id: target.model), instructions: instructions, tools: tools)
    }
    func compactIfNeeded(_ history: [Message], pending: [Message], model: ChatModel,
                         instructions: String, tools: [ToolDefinition]) async throws -> Bool {
        let target = try destination(model.id)
        return try await target.provider.compactIfNeeded(history, pending: pending, model: nativeModel(model, id: target.model), instructions: instructions, tools: tools)
    }
    func send(_ messages: [Message], model: String, effort: String?, instructions: String, tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error> {
        do {
            let target = try destination(model)
            return target.provider.send(messages, model: target.model, effort: effort, instructions: instructions, tools: tools)
        } catch { return AsyncThrowingStream { $0.finish(throwing: error) } }
    }
}
