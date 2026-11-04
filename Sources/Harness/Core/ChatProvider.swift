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

    init(id: UUID = UUID(), role: Role, text: String, status: Status = .complete,
         toolCalls: [ToolCall] = [], toolResult: ToolResult? = nil) {
        self.id = id; self.role = role; self.text = text; self.status = status
        self.toolCalls = toolCalls; self.toolResult = toolResult
    }
}

struct ChatModel: Identifiable, Sendable {
    let id: String
    let name: String
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
    // Opaque bytes are interpreted only by the provider, never by UI/storage.
    func encodeConversationState() throws -> Data?
    func restoreConversationState(_ data: Data?) throws
    func clearConversationState()
    func connect() async throws
    func disconnect() async throws
    func models() async throws -> [ChatModel]
    func send(_ messages: [Message], model: String, instructions: String, tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error>
}

extension ChatProvider {
    var conversationIdentity: String? { account }
    func encodeConversationState() throws -> Data? { nil }
    func clearConversationState() {}
    func restoreConversationState(_ data: Data?) throws {
        guard data == nil else { throw HarnessError("This provider cannot restore the saved conversation state.") }
    }
}

struct HarnessError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
