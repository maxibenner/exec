import Foundation

struct Message: Identifiable, Sendable {
    enum Role: String, Sendable { case user, assistant, tool }
    enum Status: Sendable { case complete, streaming, interrupted, failed }
    let id = UUID()
    let role: Role
    var text: String
    var status: Status = .complete
    var toolCalls: [ToolCall] = []
    var toolResult: ToolResult?
}

struct ChatModel: Identifiable, Sendable {
    let id: String
    let name: String
}

enum ChatEvent: Sendable {
    case text(String)
    case toolCall(ToolCall)
    case completed
}

// Providers own authentication and wire formats. Core orchestration sees only
// provider-neutral messages, tool definitions, and semantic events.
@MainActor protocol ChatProvider: AnyObject {
    var connectionTitle: String { get }
    var account: String? { get }
    func connect() async throws
    func disconnect() async throws
    func models() async throws -> [ChatModel]
    func send(_ messages: [Message], model: String, instructions: String, tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error>
}

struct HarnessError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
