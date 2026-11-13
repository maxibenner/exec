import Foundation

#if canImport(ExecRemote)
import ExecRemote
#endif

typealias AgentJSON = RemoteJSON

struct AgentSettings: Codable, Sendable, Equatable {
    var systemPrompt = ""
    var autoApprove = true
    var effort: String?
    var searchModel: String?
}
struct AgentLibraryConfiguration: Codable, Sendable {
    var automaticTitles = true
    var defaultModel: String?
    var settings = AgentSettings()
    var order: [UUID] = []
    private enum CodingKeys: String, CodingKey { case automaticTitles, defaultModel, settings, order }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(automaticTitles, forKey: .automaticTitles)
        try values.encode(defaultModel, forKey: .defaultModel)
        try values.encode(settings, forKey: .settings)
        try values.encode(order.map { $0.uuidString.lowercased() }, forKey: .order)
    }
}
struct AgentImage: Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let mediaType: String
    let width: Int
    let height: Int
    let byteCount: Int
    let sha256: String
    private enum CodingKeys: String, CodingKey { case id, name, mediaType, width, height, byteCount, sha256 }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id.uuidString.lowercased(), forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(mediaType, forKey: .mediaType)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
        try values.encode(byteCount, forKey: .byteCount)
        try values.encode(sha256, forKey: .sha256)
    }
}
struct AgentCall: Decodable, Sendable {
    let id: String
    let name: String
    let arguments: AgentJSON
    func presentation() throws -> ToolCall {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ToolCall(id: id, name: name, arguments: String(decoding: try encoder.encode(arguments), as: UTF8.self))
    }
}
struct AgentMessage: Decodable, Sendable {
    let id: UUID
    let role: String
    let text: String
    let status: String?
    let calls: [AgentCall]?
    let callID: String?
    let outcome: String?
    let details: AgentJSON?
    let images: [AgentImage]?
}
struct AgentOperation: Decodable, Sendable {
    let id: UUID
    let state: String
    let error: String?
    var active: Bool { ["running", "awaiting_approval", "cancelling"].contains(state) }
}
struct AgentApproval: Decodable, Sendable {
    let id: UUID
    let operationID: UUID
    let call: AgentCall
    let description: String
    let details: AgentJSON?
    let workspace: String
}
struct AgentConfiguration: Decodable, Sendable {
    let settings: AgentSettings
    let instructionsFrozen: Bool
    let workspaceInstructions: String?
}
struct AgentMetadata: Decodable, Sendable {
    let title: String?
    let manuallyNamed: Bool
    let activityAt: Double
}
struct AgentSnapshot: Decodable, Sendable {
    let id: UUID
    let model: String
    let workspace: String
    let configuration: AgentConfiguration
    let metadata: AgentMetadata
    let messages: [AgentMessage]
    let pendingInput: [AgentMessage]
    let operation: AgentOperation?
    let approval: AgentApproval?
    let activeToolCallID: String?
    let storageError: String?
    let contextUsage: ContextUsage?
}
struct AgentEvent: Decodable, Sendable {
    let type: String
    let snapshot: AgentSnapshot?
    let event: Runtime?
    struct Runtime: Decodable, Sendable {
        let type: String
        let conversationID: UUID
        let operationID: UUID
        let messageID: UUID?
        let delta: String?
    }
}

extension AgentSnapshot {
    /// Reconcile by stable message ID; pending cards are projections, never a second tool runner.
    func transcript(images: [UUID: ImageAttachment], pendingIDs: inout [String: UUID]) throws -> [Message] {
        var calls: [String: ToolCall] = [:]
        for message in messages { for call in message.calls ?? [] { calls[call.id] = try call.presentation() } }
        let answered = Set(messages.compactMap(\.callID))
        var result: [Message] = []
        for message in messages + pendingInput.filter({ pending in !messages.contains { $0.id == pending.id } }) {
            switch message.role {
            case "user":
                result.append(Message(id: message.id, role: .user, text: message.text, images: (message.images ?? []).compactMap { images[$0.id] }))
            case "assistant":
                let status: Message.Status = switch message.status {
                case "streaming": .streaming
                case "failed": .failed
                case "interrupted": .interrupted
                default: .complete
                }
                result.append(Message(id: message.id, role: .assistant, text: message.text, status: status,
                                      toolCalls: try (message.calls ?? []).map { try $0.presentation() }))
                // Existing UI shows only entered/awaiting tools, not speculative future calls.
                for call in message.calls ?? [] where !answered.contains(call.id) &&
                    (activeToolCallID == call.id || approval?.call.id == call.id) {
                    let id = pendingIDs[call.id] ?? UUID()
                    pendingIDs[call.id] = id
                    result.append(Message(id: id, role: .tool, text: "", pendingTool: .init(
                        call: try call.presentation(), isAwaitingApproval: approval?.call.id == call.id)))
                }
            case "tool":
                guard let callID = message.callID, let call = calls[callID] else { throw ExecError("The backend returned an unmatched tool result.") }
                var tool = ToolResult(call: call, text: message.text)
                tool.outcome = message.outcome
                if let details = message.details {
                    switch details["type"].string {
                    case "edit":
                        tool.edit = .init(path: details["path"].string ?? "", diff: details["diff"].string ?? "")
                    case "search": tool.webSearch = try details["result"].decoded(WebSearchResult.self)
                    case "page": tool.pageText = details["content"]["text"].string
                    case "image":
                        let reference = try details["image"].decoded(AgentImage.self)
                        if details["origin"].string == "screenshot" { tool.screenshot = images[reference.id] }
                        else { tool.generatedImage = images[reference.id] }
                    default: break
                    }
                }
                result.append(Message(id: pendingIDs[callID] ?? message.id, role: .tool, text: message.text, toolResult: tool))
            default: throw ExecError("The backend returned an unknown message role.")
            }
        }
        return result
    }
    var imageReferences: [AgentImage] {
        var refs = (messages + pendingInput).flatMap { $0.images ?? [] }
        for message in messages {
            if let details = message.details, details["type"].string == "image",
               let ref = try? details["image"].decoded(AgentImage.self) { refs.append(ref) }
        }
        return refs
    }
}
