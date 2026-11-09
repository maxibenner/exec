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
    var description: String = ""
}

struct ChatModel: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    var contextWindow: Int? = nil
    var efforts: [ChatEffort] = []
    var defaultEffort: String? = nil
    var acceptsImages: Bool? = nil
}

struct ContextUsage: Equatable, Sendable {
    let tokens: Int
    let limit: Int

    var percent: Int {
        guard limit > 0 else { return 0 }
        return Int(min(100, max(0, (Double(tokens) / Double(limit) * 100).rounded())))
    }
}

enum ChatEvent: Sendable {
    case text(String)
    case textSnapshot(String)
    case toolCall(ToolCall)
    case completed
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

// Providers own authentication and wire formats. Core orchestration sees only
// provider-neutral messages, tool definitions, and semantic events.
@MainActor protocol ChatProvider: AnyObject {
    var displayName: String { get }
    var connections: [ProviderConnection] { get }
    var retainsLocalConversations: Bool { get }
    var preservesModelSelection: Bool { get }
    var usageProviderName: String { get }
    var usageConnection: ProviderConnection? { get }
    var webSearchConfiguration: ProviderConnection.WebSearch { get }
    var modelDiscoveryWarning: String? { get }
    func recordsAccountUsage(model: String) -> Bool
    func connect(id: String, credential: String?) async throws
    func disconnect(id: String) async throws
    func isModelAvailable(_ model: String) -> Bool
    func providerID(for model: String) -> String?
    func supportsWebSearch(model: String) -> Bool
    func supportsImageGeneration(model: String) -> Bool
    func searchModel(for model: String, preferred: String) -> String
    func searchQueryLimit(model: String) -> Int?
    func usesSearchModel(_ model: String) -> Bool
    func generateImage(_ request: ImageGenerationTool.Request, model: String) async throws -> ImageAttachment
    func supportsCompaction(model: String) -> Bool
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
    func accountUsage() async throws -> AccountUsage?
    func accountBalance(providerID: String) async throws -> [AccountBalance]
    var supportsImageGeneration: Bool { get }
    func generateImage(_ request: ImageGenerationTool.Request) async throws -> ImageAttachment
    var supportsWebSearch: Bool { get }
    func contextUsage(_ messages: [Message], model: ChatModel, instructions: String, tools: [ToolDefinition]) -> ContextUsage?
    // A separate read-only request using provider-owned authentication, never conversation context.
    func searchWeb(query: String, model: String, effort: String?) async throws -> WebSearchResult
    // Compact only completed history, never pending input or unresolved tool calls.
    // A true result must be checkpointed before sending another inference request.
    var supportsCompaction: Bool { get }
    func compact(_ history: [Message], model: ChatModel, instructions: String, tools: [ToolDefinition]) async throws
    // Call willCompact exactly once when compaction is needed, before starting it.
    // Await it so the transcript can checkpoint the activity; a thrown error aborts.
    func compactIfNeeded(_ history: [Message], pending: [Message], model: ChatModel,
                         instructions: String, tools: [ToolDefinition],
                         willCompact: @MainActor () async throws -> Void) async throws -> Bool
    func send(_ messages: [Message], model: String, effort: String?, instructions: String, tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error>
}

extension ChatProvider {
    var connections: [ProviderConnection] {
        [.init(id: displayName, name: displayName, account: account,
               webSearch: webSearchConfiguration, supportsImageGeneration: supportsImageGeneration)]
    }
    var usageConnection: ProviderConnection? { connections.first { $0.account != nil } }
    var webSearchConfiguration: ProviderConnection.WebSearch { supportsWebSearch ? .model : .unavailable }
    var retainsLocalConversations: Bool { false }
    var preservesModelSelection: Bool { false }
    var usageProviderName: String { displayName }
    var modelDiscoveryWarning: String? { nil }
    func recordsAccountUsage(model: String) -> Bool { true }
    func connect(id: String, credential: String?) async throws {
        guard id == displayName else { throw ExecError("Unknown provider.") }
        try await connect()
    }
    func disconnect(id: String) async throws {
        guard id == displayName else { throw ExecError("Unknown provider.") }
        try await disconnect()
    }
    func isModelAvailable(_ model: String) -> Bool { account != nil }
    func providerID(for model: String) -> String? { model.isEmpty ? nil : displayName }
    func supportsWebSearch(model: String) -> Bool { supportsWebSearch }
    func supportsImageGeneration(model: String) -> Bool { supportsImageGeneration }
    func searchModel(for model: String, preferred: String) -> String { preferred }
    func searchQueryLimit(model: String) -> Int? { nil }
    func usesSearchModel(_ model: String) -> Bool { supportsWebSearch }
    func generateImage(_ request: ImageGenerationTool.Request, model: String) async throws -> ImageAttachment {
        try await generateImage(request)
    }
    func supportsCompaction(model: String) -> Bool { supportsCompaction }

    var supportsCompaction: Bool { false }
    func compact(_ history: [Message], model: ChatModel, instructions: String, tools: [ToolDefinition]) async throws {
        throw ExecError("This provider does not support manual compaction.")
    }

    func accountUsage() async throws -> AccountUsage? { nil }
    func accountBalance(providerID: String) async throws -> [AccountBalance] { [] }
    var conversationIdentity: String? { account }
    var supportsImageGeneration: Bool { false }
    func generateImage(_ request: ImageGenerationTool.Request) async throws -> ImageAttachment {
        throw ExecError("This provider does not support image generation.")
    }
    var supportsWebSearch: Bool { false }
    func contextUsage(_ messages: [Message], model: ChatModel, instructions: String, tools: [ToolDefinition]) -> ContextUsage? { nil }
    func searchWeb(query: String, model: String, effort: String?) async throws -> WebSearchResult {
        throw ExecError("This provider does not support web search.")
    }
    func compactIfNeeded(_ history: [Message], pending: [Message], model: ChatModel,
                         instructions: String, tools: [ToolDefinition],
                         willCompact: @MainActor () async throws -> Void = {}) async throws -> Bool { false }
    func encodeConversationState() throws -> Data? { nil }
    func clearConversationState() {}
    func restoreConversationState(_ data: Data?, history: [Message]) throws {
        guard data == nil else { throw ExecError("This provider cannot restore the saved conversation state.") }
    }
}

// Only curated app errors and provider-redacted diagnostics may be persisted
// verbatim in model context. System errors can carry sensitive userInfo.
protocol ContextSafeError: LocalizedError {}

struct ExecError: ContextSafeError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
