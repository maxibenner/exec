import Foundation

@MainActor final class OpenAIProvider: ChatProvider {
    private let authentication: OpenAIAuthentication
    private let http: URLSession
    // Preserve Responses output (including encrypted reasoning) without leaking
    // provider-specific conversation state into the UI or shared message model.
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

    func send(_ messages: [Message], model: String, instructions: String = "") -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let credentials = try await authentication.credentials()
                    try Task.checkCancellation()
                    let ids = Set(messages.map(\.id))
                    outputs = outputs.filter { ids.contains($0.key) }
                    var input: [[String: Any]] = []
                    var userID: UUID?
                    for message in messages {
                        if message.role == .user { userID = message.id }
                        if message.role == .assistant, let userID, let output = outputs[userID] {
                            guard let items = try JSONSerialization.jsonObject(with: output) as? [[String: Any]] else {
                                throw HarnessError("Invalid saved response.")
                            }
                            input.append(contentsOf: items)
                        } else {
                            input.append(["role": message.role.rawValue, "content": message.text])
                        }
                    }
                    let request = try CodexConnection.responsesRequest(
                        input: input, model: model, sessionID: messages.first?.id.uuidString ?? UUID().uuidString,
                        accessToken: credentials.access, accountID: credentials.accountID, instructions: instructions
                    )
                    for try await event in OpenAITransport.stream(request, session: http) {
                        try Task.checkCancellation()
                        switch event {
                        case .text(let delta): continuation.yield(.text(delta))
                        case .completed(let output):
                            if let userID { outputs[userID] = output }
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
