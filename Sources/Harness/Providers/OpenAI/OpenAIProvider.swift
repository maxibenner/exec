import Foundation

@MainActor final class OpenAIProvider: ChatProvider {
    private let authentication: OpenAIAuthentication
    private let http: URLSession
    // Preserve Responses output (including encrypted reasoning) without leaking
    // provider-specific conversation state into the UI or shared message model.
    // Key each model step by its final input message (user or tool result), so
    // successive tool rounds don't overwrite earlier opaque reasoning/output.
    private var outputs: [UUID: Data] = [:]
    let connectionTitle = "Connect to Codex"
    var account: String? { authentication.account }

    init(authentication: OpenAIAuthentication? = nil, http: URLSession = OpenAIHTTP.session) throws {
        self.authentication = try authentication ?? OpenAIAuthentication(http: http)
        self.http = http
    }
    func connect() async throws { try await authentication.connect() }
    func disconnect() async throws {
        outputs.removeAll()
        try await authentication.disconnect()
    }

    func models() async throws -> [ChatModel] {
        struct Catalog: Decodable {
            struct Model: Decodable { let slug: String; let display_name: String?; let visibility: String? }
            let models: [Model]
        }
        let credentials = try await authentication.credentials()
        let request = CodexConnection.modelsRequest(accessToken: credentials.access, accountID: credentials.accountID)
        let (data, response) = try await http.data(for: request)
        try OpenAIHTTP.check(response)
        return try JSONDecoder().decode(Catalog.self, from: data).models
            .filter { $0.visibility == nil || $0.visibility == "list" }
            .map { ChatModel(id: $0.slug, name: $0.display_name ?? $0.slug) }
    }

    func send(_ messages: [Message], model: String, instructions: String = "", tools: [ToolDefinition] = []) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let credentials = try await authentication.credentials()
                    try Task.checkCancellation()
                    let ids = Set(messages.map(\.id))
                    outputs = outputs.filter { ids.contains($0.key) }
                    var input: [[String: Any]] = []
                    var previousID: UUID?
                    for message in messages {
                        defer { previousID = message.id }
                        if let result = message.toolResult {
                            input.append(["type": "function_call_output", "call_id": result.call.id, "output": result.text])
                        } else if message.role == .assistant, let previousID, let output = outputs[previousID] {
                            guard let items = try JSONSerialization.jsonObject(with: output) as? [[String: Any]] else {
                                throw HarnessError("Invalid saved response.")
                            }
                            input.append(contentsOf: items)
                        } else {
                            if !message.text.isEmpty { input.append(["role": message.role.rawValue, "content": message.text]) }
                            for call in message.toolCalls {
                                input.append(["type": "function_call", "call_id": call.id, "name": call.name, "arguments": call.arguments])
                            }
                        }
                    }
                    let request = try CodexConnection.responsesRequest(
                        input: input, model: model, sessionID: messages.first?.id.uuidString ?? UUID().uuidString,
                        accessToken: credentials.access, accountID: credentials.accountID, instructions: instructions, tools: tools
                    )
                    for try await event in OpenAITransport.stream(request, session: http) {
                        try Task.checkCancellation()
                        switch event {
                        case .text(let delta): continuation.yield(.text(delta))
                        case .completed(let output):
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
                            if let previousID = messages.last?.id { outputs[previousID] = output }
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
