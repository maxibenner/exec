import Foundation

@MainActor final class OpenAIProvider: ChatProvider {
    private let authentication: OpenAIAuthentication
    private let http: URLSession
    // Preserve Responses output (including encrypted reasoning) without leaking
    // provider-specific conversation state into the UI or shared message model.
    // Key each model step by its final input message (user or tool result), so
    // successive tool rounds don't overwrite earlier opaque reasoning/output.
    private var context = CodexConversationState()
    let connectionTitle = "Connect to Codex"
    var account: String? { authentication.account }
    var conversationIdentity: String? { authentication.conversationIdentity }

    func encodeConversationState() throws -> Data? {
        try JSONEncoder().encode(context)
    }

    func clearConversationState() { context = CodexConversationState() }

    func restoreConversationState(_ data: Data?, history: [Message]) throws {
        do {
            let restored = try CodexConversationState.restore(data)
            if let prefix = restored.prefix, !history.contains(where: { $0.id == prefix.throughID }) {
                throw HarnessError("Compacted context does not match the saved history.")
            }
            context = restored
        } catch { throw HarnessError("Saved Codex response context could not be read. Start a new conversation.") }
    }

    init(authentication: OpenAIAuthentication? = nil, http: URLSession = OpenAIHTTP.session) throws {
        self.authentication = try authentication ?? OpenAIAuthentication(http: http)
        self.http = http
    }
    static func restored() async throws -> OpenAIProvider {
        try await OpenAIProvider(authentication: OpenAIAuthentication.restored())
    }

    func makeConversationProvider() throws -> any ChatProvider {
        try OpenAIProvider(authentication: authentication, http: http)
    }

    func connect() async throws { try await authentication.connect() }
    func disconnect() async throws {
        defer { if authentication.account == nil { clearConversationState() } }
        try await authentication.disconnect()
    }

    func models() async throws -> [ChatModel] {
        struct Catalog: Decodable {
            struct Model: Decodable {
                let slug: String
                let display_name: String?
                let visibility: String?
                let context_window: Int?
                let effective_context_window_percent: Int?
                struct Effort: Decodable {
                    let effort: String
                    let description: String?
                }
                let supported_reasoning_levels: [Effort]?
                let default_reasoning_level: String?
            }
            let models: [Model]
        }
        let credentials = try await authentication.credentials()
        let request = CodexConnection.modelsRequest(accessToken: credentials.access, accountID: credentials.accountID)
        let (data, response) = try await http.data(for: request)
        try OpenAIHTTP.check(response)
        return try JSONDecoder().decode(Catalog.self, from: data).models
            .filter { $0.visibility == nil || $0.visibility == "list" }
            .map {
                let percent = $0.effective_context_window_percent ?? 100
                let window = $0.context_window.flatMap { size -> Int? in
                    guard (1...10_000_000).contains(size), (1...100).contains(percent) else { return nil }
                    return size * percent / 100
                }
                var seen = Set<String>()
                let efforts = ($0.supported_reasoning_levels ?? []).compactMap { level -> ChatEffort? in
                    guard !level.effort.isEmpty, level.effort.utf8.count <= 64,
                          seen.insert(level.effort).inserted else { return nil }
                    let name = level.effort == "xhigh" ? "Extra High" : level.effort.capitalized
                    return ChatEffort(id: level.effort, name: name, description: level.description ?? "")
                }
                return ChatModel(id: $0.slug, name: $0.display_name ?? $0.slug, contextWindow: window,
                                 efforts: efforts, defaultEffort: $0.default_reasoning_level)
            }
    }

    let supportsWebSearch = true

    func searchWeb(query: String, model: String, effort: String?) async throws -> WebSearchResult {
        let query = try WebSearchTool.validatedQuery(query)
        try Task.checkCancellation()
        let credentials = try await authentication.credentials()
        try Task.checkCancellation()
        let request = try CodexConnection.webSearchRequest(query: query, model: model, effort: effort,
            accessToken: credentials.access, accountID: credentials.accountID)
        for try await event in OpenAITransport.stream(request, session: http) {
            try Task.checkCancellation()
            if case .completed(let output, _) = event {
                return try CodexWebSearch.result(output, query: query)
            }
        }
        try Task.checkCancellation()
        throw HarnessError("Web search ended before completion. No retry was made.")
    }

    func contextUsage(_ messages: [Message], model: ChatModel, instructions: String, tools: [ToolDefinition]) -> ContextUsage? {
        guard let limit = model.contextWindow, limit > 0 else { return nil }
        guard !messages.isEmpty else { return ContextUsage(tokens: 0, limit: limit, isEstimated: false) }
        guard let tokens = try? context.estimatedTokens(messages, overhead: Self.contextOverhead(instructions: instructions, tools: tools)) else { return nil }
        let reported: Bool
        if let measurement = context.measurement, messages.count >= 2 {
            reported = messages[messages.count - 2].id == measurement.inputID && messages.last?.role == .assistant
        } else { reported = false }
        return ContextUsage(tokens: tokens, limit: limit, isEstimated: !reported)
    }

    private static func contextOverhead(instructions: String, tools: [ToolDefinition]) -> Int {
        let toolBytes = tools.reduce(0) { total, tool in
            total + tool.name.utf8.count + tool.description.utf8.count + 256 + tool.parameters.reduce(0) {
                $0 + $1.name.utf8.count + $1.type.utf8.count + $1.description.utf8.count + 64
            }
        }
        return (CodexConnection.systemInstructions(instructions).utf8.count + toolBytes + 2) / 3
    }

    func compactIfNeeded(_ history: [Message], pending: [Message], model: ChatModel,
                         instructions: String, tools: [ToolDefinition]) async throws -> Bool {
        guard let window = model.contextWindow, window > 0 else {
            throw HarnessError("Codex did not provide a context limit for this model. Refresh models before sending.")
        }
        let overhead = Self.contextOverhead(instructions: instructions, tools: tools)
        let tokens = try context.estimatedTokens(history + pending, overhead: overhead)
        guard tokens >= Int(ceil(Double(window) * 0.95)) else { return false }
        guard let boundary = history.last?.id else {
            throw HarnessError("The input is too large and there is no completed history to compact. Shorten the message.")
        }
        // Never summarize an unanswered call or treat compaction output as executable tools.
        var unanswered = Set<String>()
        for message in history {
            unanswered.formUnion(message.toolCalls.map(\.id))
            if let result = message.toolResult { unanswered.remove(result.call.id) }
        }
        guard unanswered.isEmpty else {
            throw HarnessError("Cannot compact while tool results are unresolved.")
        }
        let credentials = try await authentication.credentials()
        try Task.checkCancellation()
        let request = try CodexConnection.compactRequest(
            input: context.input(history), model: model.id, sessionID: history.first!.id.uuidString,
            accessToken: credentials.access, accountID: credentials.accountID, instructions: instructions
        )
        let data = try await OpenAITransport.boundedResponse(request, session: http)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = response["output"] as? [[String: Any]] else {
            throw HarnessError("Codex returned invalid compacted context. The original conversation was kept.")
        }
        let compacted = try JSONSerialization.data(withJSONObject: output)
        try CodexConversationState.validateCompaction(compacted)
        try Task.checkCancellation()
        context = CodexConversationState(prefix: .init(throughID: boundary, output: compacted))
        return true
    }

    func send(_ messages: [Message], model: String, effort: String? = nil, instructions: String = "", tools: [ToolDefinition] = []) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let credentials = try await authentication.credentials()
                    try Task.checkCancellation()
                    let ids = Set(messages.map(\.id))
                    context.outputs = context.outputs.filter { ids.contains($0.key) }
                    let input = try context.input(messages)
                    let request = try CodexConnection.responsesRequest(
                        input: input, model: model, sessionID: messages.first?.id.uuidString ?? UUID().uuidString,
                        accessToken: credentials.access, accountID: credentials.accountID, instructions: instructions, tools: tools,
                        effort: effort
                    )
                    for try await event in OpenAITransport.stream(request, session: http) {
                        try Task.checkCancellation()
                        switch event {
                        case .text(let delta): continuation.yield(.text(delta))
                        case .completed(let output, let tokens):
                            guard let items = try JSONSerialization.jsonObject(with: output) as? [[String: Any]] else {
                                throw HarnessError("Invalid tool response.")
                            }
                            // Final message content is authoritative. Some streams omit
                            // deltas or supply only a prefix; replace rather than append.
                            let parts = items.filter { $0["type"] as? String == "message" }
                                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                                .compactMap { part -> String? in
                                    switch part["type"] as? String {
                                    case "output_text": return part["text"] as? String
                                    case "refusal": return part["refusal"] as? String
                                    default: return nil
                                    }
                                }
                            if !parts.isEmpty { continuation.yield(.textSnapshot(parts.joined())) }
                            for item in items where item["type"] as? String == "function_call" {
                                guard let id = item["call_id"] as? String, !id.isEmpty,
                                      let name = item["name"] as? String, !name.isEmpty,
                                      let arguments = item["arguments"] as? String else {
                                    throw HarnessError("Invalid tool call.")
                                }
                                continuation.yield(.toolCall(ToolCall(id: id, name: name, arguments: arguments)))
                            }
                            if let previousID = messages.last?.id {
                                context.outputs[previousID] = output
                                context.measurement = tokens.map { .init(inputID: previousID, tokens: $0) }
                            }
                            continuation.yield(.completed)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
