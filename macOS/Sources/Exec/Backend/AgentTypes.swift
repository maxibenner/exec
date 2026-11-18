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
    var defaultDisabledTools: [String] = ["shell"]
    var settings = AgentSettings()
    var order: [UUID] = []
    private enum CodingKeys: String, CodingKey { case automaticTitles, defaultModel, defaultDisabledTools, settings, order }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(automaticTitles, forKey: .automaticTitles)
        try values.encode(defaultModel, forKey: .defaultModel)
        try values.encode(defaultDisabledTools, forKey: .defaultDisabledTools)
        try values.encode(settings, forKey: .settings)
        try values.encode(order.map { $0.uuidString.lowercased() }, forKey: .order)
    }
}
extension AgentLibraryConfiguration {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        automaticTitles = try values.decode(Bool.self, forKey: .automaticTitles)
        defaultModel = try values.decodeIfPresent(String.self, forKey: .defaultModel)
        defaultDisabledTools = try values.decodeIfPresent([String].self, forKey: .defaultDisabledTools) ?? ["shell"]
        settings = try values.decode(AgentSettings.self, forKey: .settings)
        order = try values.decode([UUID].self, forKey: .order)
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
struct AgentFile: Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let path: String
    let byteCount: Int
    let sha256: String
}
struct AgentCall: Decodable, Sendable, Equatable {
    let id: String
    let name: String
    let arguments: AgentJSON
    func presentation() throws -> ToolCall {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return ToolCall(id: id, name: name, arguments: String(decoding: try encoder.encode(arguments), as: UTF8.self))
    }
}
struct AgentMessage: Decodable, Sendable, Equatable {
    let id: UUID
    let role: String
    let text: String
    let status: String?
    let calls: [AgentCall]?
    let callID: String?
    let outcome: String?
    let details: AgentJSON?
    let images: [AgentImage]?
    let files: [AgentFile]?
}
struct AgentOperation: Decodable, Sendable, Equatable {
    let id: UUID
    let state: String
    let error: String?
    var active: Bool { ["running", "awaiting_approval", "cancelling"].contains(state) }
}
struct AgentApproval: Decodable, Sendable, Equatable {
    let id: UUID
    let operationID: UUID
    let call: AgentCall
    let description: String
    let details: AgentJSON?
    let workspace: String
}
struct AgentConfiguration: Decodable, Sendable, Equatable {
    let settings: AgentSettings
    let instructionsFrozen: Bool
    let workspaceInstructions: String?
}
struct AgentSessionParent: Decodable, Equatable, Sendable {
    let sessionId: UUID
    let operationId: UUID
    let toolCallId: String
}
struct AgentMetadata: Decodable, Sendable, Equatable {
    let disabledTools: [String]?
    let parent: AgentSessionParent?
    let title: String?
    let manuallyNamed: Bool
    let activityAt: Double
}
struct AgentSnapshot: Decodable, Sendable, Equatable {
    let id: UUID
    let model: String
    let workspace: String
    let configuration: AgentConfiguration
    let metadata: AgentMetadata
    var messages: [AgentMessage]
    let pendingInput: [AgentMessage]
    let operation: AgentOperation?
    let approval: AgentApproval?
    let activeToolCallID: String?
    let activeToolName: String?
    let storageError: String?
    let contextUsage: ContextUsage?
}

extension AgentSnapshot {
    /// Reconcile by stable message ID; pending cards are projections, never a second tool runner.
    func transcript(images: [UUID: ImageAttachment], pendingIDs: inout [String: UUID]) throws -> [Message] {
        var calls: [String: ToolCall] = [:]
        for message in messages { for call in message.calls ?? [] { calls[call.id] = try call.presentation() } }
        // A running delegate result already occupies its tool row, but does not
        // mean the executor has settled. Keep activity separate from row presence.
        let represented = Set(messages.filter { $0.role == "tool" }.compactMap(\.callID))
        var result: [Message] = []
        for message in messages + pendingInput.filter({ pending in !messages.contains { $0.id == pending.id } }) {
            switch message.role {
            case "user":
                result.append(Message(id: message.id, role: .user, text: message.text, images: (message.images ?? []).compactMap { images[$0.id] },
                                      files: (message.files ?? []).map { FileAttachment(id: $0.id, name: $0.name, path: $0.path) }))
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
                for call in message.calls ?? [] where !represented.contains(call.id) &&
                    (activeToolCallID == call.id || approval?.call.id == call.id) {
                    let id = pendingIDs[call.id] ?? UUID()
                    pendingIDs[call.id] = id
                    result.append(Message(id: id, role: .tool, text: "",
                        status: activeToolCallID == call.id ? .streaming : .complete, pendingTool: .init(
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
                    // Delegation details remain lossless in AgentMessage. Its text
                    // already contains the settled children in original task order.
                    default: break
                    }
                }
                let running = activeToolCallID == callID || message.outcome == "running"
                result.append(Message(id: pendingIDs[callID] ?? message.id, role: .tool, text: message.text,
                                      status: running ? .streaming : .complete, toolResult: tool))
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
