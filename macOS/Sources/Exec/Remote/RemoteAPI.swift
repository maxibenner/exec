import CryptoKit
import Foundation

/// An intentionally small, provider-neutral protocol. Never serialize a session
/// snapshot: it contains opaque provider state, account identities and images.
struct RemoteConversationSummary: Encodable {
    let id: UUID
    let title: String
    let workspace: String?
    let running: Bool
    let needsApproval: Bool
    let unreadable: Bool
}

struct RemoteTranscript: Encodable {
    struct Row: Encodable {
        struct Tool: Encodable {
            let title: String
            let arguments: String
            let output: String
            let isDiff: Bool
        }
        let id: UUID
        let role: String
        let text: String
        let status: String
        let pending: Bool
        let imageCount: Int
        let tool: Tool?

        init(_ message: Message, pendingIDs: Set<UUID>) {
            id = message.id; role = message.role.rawValue; status = message.status.rawValue
            text = message.compaction == nil ? message.text : "Context compaction"
            pending = pendingIDs.contains(id)
            imageCount = message.images.count + (message.toolResult?.screenshot == nil ? 0 : 1) +
                (message.toolResult?.generatedImage == nil ? 0 : 1)
            if let call = message.pendingTool?.call ?? message.toolResult?.call {
                let presentation = ToolPresentation(call: call, result: message.toolResult)
                tool = Tool(title: presentation.title, arguments: call.arguments,
                            output: message.toolResult?.edit?.diff ?? presentation.output,
                            isDiff: message.toolResult?.edit != nil)
            } else { tool = nil }
        }
    }
    let id: UUID
    let title: String
    let messages: [Row]
    let canSend: Bool
    let operationID: UUID?
    let needsApproval: Bool
    let error: String?

    @MainActor init(_ conversation: ChatStore, id: UUID, title: String) {
        self.id = id; self.title = title
        let pendingIDs = Set(conversation.pendingInput.map(\.id))
        messages = conversation.messages.map { Row($0, pendingIDs: pendingIDs) }
        canSend = conversation.canSendRemoteMessage
        operationID = (conversation.isSending || conversation.isCompacting) && !conversation.isStopping ? conversation.operationID : nil
        needsApproval = conversation.tools.pendingApproval != nil
        error = conversation.error
    }
}

@MainActor final class RemoteAPI {
    struct Command: Codable, Equatable {
        let serverID: UUID
        let requestID: UUID
        var text: String?
        var operationID: UUID?
        var workspacePath: String?
    }
    private struct FolderRequest: Decodable { let path: String? }
    struct Receipt: Codable {
        let serverID: UUID
        let requestID: UUID
        let accepted: Bool
    }
    private struct Accepted {
        let path: String
        let command: Command
    }
    private struct Catalog: Encodable {
        let serverID: UUID
        let conversations: [RemoteConversationSummary]
        let descriptiveShellTitles: Bool
    }
    let serverID = UUID()
    private let library: ChatLibrary
    private var allowedOrigins: Set<String>
    private let assets: [String: RemoteHTTPResponse]
    private var accepted: [UUID: Accepted] = [:]
    private var creating: Set<UUID> = []
    private let homeDirectory: URL
    private(set) var active = true

    init(library: ChatLibrary, assets: [String: RemoteHTTPResponse] = [:],
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         allowedOrigins: Set<String> = [RemoteAccess.address]) {
        self.library = library; self.allowedOrigins = allowedOrigins; self.assets = assets
        self.homeDirectory = homeDirectory
    }

    func allowLoopback(port: UInt16) {
        allowedOrigins.formUnion(["http://127.0.0.1:\(port)", "http://localhost:\(port)"])
    }

    func invalidate() { active = false }

    func handle(_ request: RemoteHTTPRequest) async -> RemoteHTTPResponse {
        guard active, !Task.isCancelled else { return .error(503, "Mobile access is disabled.") }
        guard allowsOrigin(request) else { return .error(403, "Cross-origin requests are not allowed.") }
        if request.method == "GET", let asset = assets[request.path] { return asset }
        guard request.path.hasPrefix("/api/") else { return .error(404, "Not found.") }
        guard !library.isPresentingStartup else { return .error(503, "Exec has not finished restoring on the Mac.") }
        do {
            if request.method == "GET", request.path == "/api/conversations" {
                let rows = library.sessionList.map {
                    RemoteConversationSummary(id: $0.id, title: $0.title,
                        workspace: $0.workspace.map { URL(fileURLWithPath: $0).lastPathComponent },
                        running: library.isSessionResponding($0.id), needsApproval: library.needsApproval($0.id), unreadable: $0.unreadable)
                }
                return try conditional(Catalog(serverID: serverID, conversations: rows,
                                               descriptiveShellTitles: library.descriptiveShellTitles), request: request)
            }
            // A read-only POST keeps local filesystem paths out of proxy URLs/logs.
            if request.method == "POST", request.path == "/api/folders" {
                guard request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json",
                      let query = try? JSONDecoder().decode(FolderRequest.self, from: request.body) else {
                    return .error(400, "Expected a folder request.")
                }
                let path = query.path ?? homeDirectory.path
                do {
                    let listing = try await Task.detached { try RemoteFolders.list(path) }.value
                    guard active, !Task.isCancelled else { throw CancellationError() }
                    return try .json(listing)
                } catch is CancellationError { throw CancellationError() }
                catch { return .error(409, "Cannot open this folder. Check its path and permissions on the Mac.") }
            }
            let parts = request.path.split(separator: "/", omittingEmptySubsequences: false)
            if request.method == "GET", parts.count == 4, parts[2] == "commands", let id = UUID(uuidString: String(parts[3])) {
                return try .json(Receipt(serverID: serverID, requestID: id, accepted: accepted[id] != nil))
            }
            let isCreation = request.path == "/api/conversations" && request.method == "POST"
            let id = parts.count >= 4 ? UUID(uuidString: String(parts[3])) : nil
            guard isCreation || ((parts.count == 4 || parts.count == 5) && parts[1] == "api" && parts[2] == "conversations" && id != nil) else {
                return .error(404, "Not found.")
            }
            if request.method == "GET", parts.count == 4, let id {
                let title = library.sessionList.first(where: { $0.id == id })?.title ?? "Conversation"
                return try await library.withRemoteConversation(id) { conversation in
                    guard active, !Task.isCancelled else { throw CancellationError() }
                    return try conditional(RemoteTranscript(conversation, id: id, title: title), request: request)
                }
            }
            guard request.method == "POST", isCreation || (parts.count == 5 && ["messages", "stop"].contains(parts[4])) else {
                return .error(404, "Not found.")
            }
            guard request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json",
                  let command = try? JSONDecoder().decode(Command.self, from: request.body) else {
                return .error(400, "Expected a JSON command.")
            }
            guard command.serverID == serverID else { return .error(409, "Exec restarted or mobile access changed. Refresh before sending another command.") }
            if let previous = accepted[command.requestID] {
                guard previous.path == request.path, previous.command == command else { return .error(409, "Request ID was already used for another command.") }
                return try .json(Receipt(serverID: serverID, requestID: command.requestID, accepted: true), status: 202)
            }
            // Never evict deduplication records within an epoch. Rotate the epoch
            // on restart; old commands are rejected, not silently executed twice.
            guard !creating.contains(command.requestID) else { return .error(409, "Creation is still pending. Check its receipt.") }
            guard accepted.count + creating.count < 10_000 else { return .error(503, "Disable and re-enable mobile access on the Mac before sending more commands.") }
            if isCreation {
                guard let path = command.workspacePath, command.text == nil, command.operationID == nil else {
                    return .error(400, "Choose a workspace folder on the Mac.")
                }
                creating.insert(command.requestID)
                defer { creating.remove(command.requestID) }
                let workspace = try await Task.detached {
                    try Workspace.load(RemoteFolders.directory(path))
                }.value
                guard active, !Task.isCancelled else { throw CancellationError() }
                try await library.createRemoteConversation(id: command.requestID, workspace: workspace)
                accepted[command.requestID] = Accepted(path: request.path, command: command)
                return try .json(Receipt(serverID: serverID, requestID: command.requestID, accepted: true), status: 202)
            }
            guard let id, command.workspacePath == nil else { return .error(400, "Unexpected workspace.") }
            return try await library.withRemoteConversation(id) { conversation in
                guard active, !Task.isCancelled else { throw CancellationError() }
                if parts[4] == "messages" {
                    guard let text = command.text, command.operationID == nil else { return .error(400, "Expected message text.") }
                    try conversation.sendRemoteMessage(text, id: command.requestID)
                } else {
                    guard command.text == nil, let operationID = command.operationID,
                          operationID == conversation.operationID,
                          conversation.isSending || conversation.isCompacting else {
                        return .error(409, "That operation has already ended. Refresh the conversation.")
                    }
                    conversation.stop()
                }
                accepted[command.requestID] = Accepted(path: request.path, command: command)
                return try .json(Receipt(serverID: serverID, requestID: command.requestID, accepted: true), status: 202)
            }
        } catch is CancellationError {
            return .error(503, "Request interrupted. Check the conversation before sending again.")
        } catch {
            // Raw storage/provider errors can include local account data. Only
            // the transcript's intentional user-facing error is exported.
            return .error(409, "Conversation unavailable or unable to accept this command. Check it on the Mac.")
        }
    }

    private func conditional<T: Encodable>(_ value: T, request: RemoteHTTPRequest) throws -> RemoteHTTPResponse {
        var response = try RemoteHTTPResponse.json(value)
        let digest = SHA256.hash(data: response.body).map { String(format: "%02x", $0) }.joined()
        response.etag = "\"\(digest)\""
        if request.headers["if-none-match"] == response.etag {
            response.status = 304; response.body = Data()
        }
        return response
    }

    private func allowsOrigin(_ request: RemoteHTTPRequest) -> Bool {
        // Host is an explicit allowlist, not a reflection of an attacker-controlled
        // Origin. This applies to assets too, preventing DNS-rebinding bootstrap.
        guard let host = request.headers["host"]?.lowercased(),
              allowedOrigins.contains(where: { $0.components(separatedBy: "://").last == host }) else { return false }
        // Pangolin sign-in may redirect from a different origin. Only a top-level
        // GET navigation to the static shell may cross origins; no API data or
        // mutation is exposed here. Frames remain prohibited by CSP/X-Frame-Options.
        if request.method == "GET", request.path == "/",
           request.headers["sec-fetch-mode"] == "navigate",
           request.headers["sec-fetch-dest"] == "document" { return true }
        guard !["cross-site", "same-site"].contains(request.headers["sec-fetch-site"] ?? "") else { return false }
        guard let origin = request.headers["origin"] else { return request.method == "GET" }
        guard let normalized = PangolinConfiguration.origin(origin),
              origin.lowercased() == normalized, allowedOrigins.contains(normalized),
              normalized.components(separatedBy: "://").last == host else { return false }
        // No CORS, forwarded identity headers, or proxy-supplied authentication.
        return request.method == "GET" || request.headers["x-exec-request"] == "1"
    }
}
