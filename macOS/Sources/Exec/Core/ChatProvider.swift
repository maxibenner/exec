import Foundation

struct Message: Identifiable, Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable { case user, assistant, tool }
    enum Status: String, Codable, Sendable { case complete, streaming, interrupted, failed }
    let id: UUID
    let role: Role
    var text: String
    var status: Status = .complete
    var toolCalls: [ToolCall] = []
    var toolResult: ToolResult?
    // Transcript-only request state. Never added to provider history as an outcome.
    struct PendingTool: Codable, Sendable, Equatable {
        let call: ToolCall
        var isAwaitingApproval = false
    }
    var pendingTool: PendingTool?
    // App-owned activity, persisted only in the transcript, never model history.
    enum Compaction: String, Codable, Sendable { case manual, automatic }
    var compaction: Compaction?
    var images: [ImageAttachment]

    init(id: UUID = UUID(), role: Role, text: String, status: Status = .complete,
         toolCalls: [ToolCall] = [], toolResult: ToolResult? = nil, images: [ImageAttachment] = [],
         pendingTool: PendingTool? = nil, compaction: Compaction? = nil) {
        self.id = id; self.role = role; self.text = text; self.status = status
        self.toolCalls = toolCalls; self.toolResult = toolResult; self.images = images
        self.pendingTool = pendingTool
        self.compaction = compaction
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, status, toolCalls, toolResult, images, pendingTool, compaction
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        status = try values.decode(Status.self, forKey: .status)
        toolCalls = try values.decode([ToolCall].self, forKey: .toolCalls)
        toolResult = try values.decodeIfPresent(ToolResult.self, forKey: .toolResult)
        pendingTool = try values.decodeIfPresent(PendingTool.self, forKey: .pendingTool)
        compaction = try values.decodeIfPresent(Compaction.self, forKey: .compaction)
        images = try values.decodeIfPresent([ImageAttachment].self, forKey: .images) ?? []
        try ImageAttachment.validate(images)
    }
}

struct ChatEffort: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
}

struct ChatModel: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    var contextWindow: Int? = nil
    var efforts: [ChatEffort] = []
    var defaultEffort: String? = nil
    var acceptsImages: Bool? = nil
}

struct ContextUsage: Codable, Equatable, Sendable {
    let tokens: Int
    let limit: Int

    var percent: Int {
        guard limit > 0 else { return 0 }
        return Int(min(100, max(0, (Double(tokens) / Double(limit) * 100).rounded())))
    }
}

struct ProviderConnection: Identifiable, Equatable {
    enum Authentication { case browser, apiKey }
    enum WebSearch: Equatable { case unavailable, model, service(String) }
    let id: String
    let name: String
    let account: String?
    var authentication: Authentication = .browser
    var webSearch: WebSearch = .unavailable
    var supportsImageGeneration = false
    var balanceIdentity: String? = nil
}

// UI depends only on this provider-neutral account/catalog interface.
// Conversation execution belongs exclusively to the Rust service.
@MainActor protocol ChatProvider: AnyObject {
    var api: AgentAPI { get }
    var connections: [ProviderConnection] { get }
    var account: String? { get }
    func refreshConnections() async throws
    func models() async throws -> [ChatModel]
    func connect(id: String, credential: String?) async throws
    func disconnect(id: String) async throws
    func cancelConnection() async
    func isModelAvailable(_ model: String) -> Bool
    func providerID(for model: String) -> String?
}

struct ExecError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
