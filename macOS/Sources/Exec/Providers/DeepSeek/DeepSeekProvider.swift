import Foundation

@MainActor final class DeepSeekProvider: ChatProvider {
    let displayName = "DeepSeek"
    let connectionTitle = "Connect DeepSeek in Settings"
    private let authentication: DeepSeekAuthentication
    private let http: URLSession
    private var context = DeepSeekConversationState()
    var account: String? { authentication.account }
    var conversationIdentity: String? { authentication.identity }
    var connections: [ProviderConnection] {
        [.init(id: displayName, name: displayName, account: account, authentication: .apiKey)]
    }

    init(authentication: DeepSeekAuthentication, http: URLSession = DeepSeekHTTP.session) {
        self.authentication = authentication
        self.http = http
    }
    static func restored() async throws -> DeepSeekProvider {
        try await DeepSeekProvider(authentication: DeepSeekAuthentication.restored())
    }
    func makeConversationProvider() throws -> any ChatProvider { DeepSeekProvider(authentication: authentication, http: http) }
    func connect() async throws { throw ExecError("Enter your DeepSeek API key in Settings.") }
    func connect(id: String, credential: String?) async throws {
        guard id == displayName, let credential else { throw ExecError("Enter your DeepSeek API key in Settings.") }
        try await authentication.connect(key: credential, http: http)
    }
    func disconnect() async throws { try authentication.disconnect(); clearConversationState() }
    func models() async throws -> [ChatModel] { try await authentication.models(http: http) }
    func clearConversationState() { context = DeepSeekConversationState() }
    func encodeConversationState() throws -> Data? { try JSONEncoder().encode(context) }
    func restoreConversationState(_ data: Data?, history: [Message]) throws {
        guard let data else { clearConversationState(); return }
        guard let state = try? JSONDecoder().decode(DeepSeekConversationState.self, from: data), state.version == 1,
              state.reasoning.values.allSatisfy({ $0.utf8.count <= 4 * 1024 * 1024 }),
              state.measurement.map({ (0...1_000_000_000).contains($0.tokens) }) ?? true else {
            throw ExecError("Saved DeepSeek response context could not be read.")
        }
        context = state
    }
    func contextUsage(_ messages: [Message], model: ChatModel, instructions: String, tools: [ToolDefinition]) -> ContextUsage? {
        guard let measurement = context.measurement, measurement.model == model.id,
              let index = messages.firstIndex(where: { $0.id == measurement.inputID }), index + 1 < messages.count,
              messages[index + 1].role == .assistant, messages[index + 1].status == .complete,
              let limit = model.contextWindow else { return nil }
        return ContextUsage(tokens: measurement.tokens, limit: limit)
    }

    func send(_ messages: [Message], model: String, effort: String?, instructions: String,
              tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try Task.checkCancellation()
                    let key = try authentication.key()
                    // Catalog is shared across conversation providers, unlike response state.
                    if authentication.catalog.isEmpty { _ = try await models() }
                    try Task.checkCancellation()
                    guard let selected = authentication.catalog.first(where: { $0.id == model }) else {
                        throw ExecError("The selected DeepSeek model is unavailable. Select another model, or remove and add DeepSeek in Settings → Providers.")
                    }
                    var body: [String: Any] = ["model": model, "stream": true, "stream_options": ["include_usage": true],
                        "messages": try context.input(messages, instructions: instructions, acceptsImages: selected.acceptsImages == true)]
                    if let effort {
                        guard selected.efforts.contains(where: { $0.id == effort }) else { throw ExecError("Unsupported DeepSeek reasoning level.") }
                        body["reasoning_effort"] = effort
                        body["thinking"] = ["type": effort == "none" ? "disabled" : "enabled"]
                    }
                    if !tools.isEmpty {
                        body["tools"] = tools.map { definition in
                            ["type": "function", "function": [
                                "name": definition.name, "description": definition.description,
                                "parameters": ["type": "object", "properties": Dictionary(uniqueKeysWithValues: definition.parameters.map {
                                    ($0.name, ["type": $0.type, "description": $0.description])
                                }), "required": definition.parameters.map(\.name), "additionalProperties": false]
                            ]] as [String: Any]
                        }
                    }
                    let request = DeepSeekHTTP.request("chat/completions", key: key, body: try JSONSerialization.data(withJSONObject: body))
                    for try await event in DeepSeekTransport.stream(request, session: http) {
                        try Task.checkCancellation()
                        switch event {
                        case .text(let text): continuation.yield(.text(text))
                        case .completed(let output):
                            if let inputID = messages.last?.id {
                                context.reasoning[inputID] = output.reasoning
                                context.measurement = output.tokens.map { .init(inputID: inputID, model: model, tokens: $0) }
                            }
                            for call in output.calls { continuation.yield(.toolCall(call)) }
                            continuation.yield(.completed)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func usesSearchModel(_ model: String) -> Bool { false }
    func searchQueryLimit(model: String) -> Int? { 128 }
    let supportsWebSearch = true
    func searchWeb(query: String, model: String, effort: String?) async throws -> WebSearchResult {
        try Task.checkCancellation()
        let query = try WebSearchTool.validatedQuery(query)
        guard query.unicodeScalars.count <= 128 else { throw ExecError("DeepSeek search queries must contain at most 128 characters.") }
        var request = DeepSeekHTTP.request("v1/tools/search", key: try authentication.key(),
            body: try JSONSerialization.data(withJSONObject: ["query": query, "count": 10, "need_content": false]))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await DeepSeekHTTP.data(request, session: http)
        try Task.checkCancellation()
        return try DeepSeekWebSearch.result(data, query: query)
    }
}
