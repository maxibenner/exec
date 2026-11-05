import Foundation

struct Message: Identifiable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, tool }
    enum Status: String, Codable, Sendable { case complete, streaming, interrupted, failed }
    let id: UUID
    let role: Role
    var text: String
    var status: Status = .complete
    var toolCalls: [ToolCall] = []
    var toolResult: ToolResult?
    var images: [ImageAttachment]

    init(id: UUID = UUID(), role: Role, text: String, status: Status = .complete,
         toolCalls: [ToolCall] = [], toolResult: ToolResult? = nil, images: [ImageAttachment] = []) {
        self.id = id; self.role = role; self.text = text; self.status = status
        self.toolCalls = toolCalls; self.toolResult = toolResult; self.images = images
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, status, toolCalls, toolResult, images
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        status = try values.decode(Status.self, forKey: .status)
        toolCalls = try values.decode([ToolCall].self, forKey: .toolCalls)
        toolResult = try values.decodeIfPresent(ToolResult.self, forKey: .toolResult)
        images = try values.decodeIfPresent([ImageAttachment].self, forKey: .images) ?? []
        try ImageAttachment.validate(images)
    }
}

struct ChatEffort: Identifiable, Sendable {
    let id: String
    let name: String
    var description: String = ""
}

struct ChatModel: Identifiable, Sendable {
    let id: String
    let name: String
    var contextWindow: Int? = nil
    var efforts: [ChatEffort] = []
    var defaultEffort: String? = nil
}

enum ChatEvent: Sendable {
    case text(String)
    case textSnapshot(String)
    case toolCall(ToolCall)
    case completed
}

// Providers own authentication and wire formats. Core orchestration sees only
// provider-neutral messages, tool definitions, and semantic events.
@MainActor protocol ChatProvider: AnyObject {
    var connectionTitle: String { get }
    var account: String? { get }
    var conversationIdentity: String? { get }
    // Share account authentication, but isolate mutable response context for each conversation.
    func makeConversationProvider() throws -> any ChatProvider
    // Opaque bytes are interpreted only by the provider, never by UI/storage.
    func encodeConversationState() throws -> Data?
    func restoreConversationState(_ data: Data?, history: [Message]) throws
    func clearConversationState()
    func connect() async throws
    func disconnect() async throws
    func models() async throws -> [ChatModel]
    // Compact only completed history, never pending input or unresolved tool calls.
    // A true result must be checkpointed before sending another inference request.
    func compactIfNeeded(_ history: [Message], pending: [Message], model: ChatModel,
                         instructions: String, tools: [ToolDefinition]) async throws -> Bool
    func send(_ messages: [Message], model: String, effort: String?, instructions: String, tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error>
}

extension ChatProvider {
    var conversationIdentity: String? { account }
    func compactIfNeeded(_ history: [Message], pending: [Message], model: ChatModel,
                         instructions: String, tools: [ToolDefinition]) async throws -> Bool { false }
    func encodeConversationState() throws -> Data? { nil }
    func clearConversationState() {}
    func restoreConversationState(_ data: Data?, history: [Message]) throws {
        guard data == nil else { throw HarnessError("This provider cannot restore the saved conversation state.") }
    }
}

struct HarnessError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
