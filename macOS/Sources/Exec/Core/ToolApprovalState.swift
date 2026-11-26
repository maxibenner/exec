import Foundation
import Observation

/// Presentation of a single Rust-owned approval. No tool execution or local auto-approval.
@MainActor @Observable final class ToolApprovalState {
    struct Approval: Identifiable {
        let id: UUID
        enum Kind { case shell, edit, screenshot, other }
        let kind: Kind
        let content: String
        let directory: URL
        let filePath: String?
        var timeoutSeconds: Int?
    }
    private(set) var pendingApproval: Approval?
    private var operationID: UUID?
    private var resolving = false
    var resolve: ((UUID, UUID, Bool) async throws -> Void)?
    var reportError: ((String) -> Void)?

    func apply(_ approval: AgentApproval?) throws {
        operationID = approval?.operationID
        guard let approval else { pendingApproval = nil; return }
        let call = try approval.call.presentation()
        let kind: Approval.Kind = switch call.name {
        case "shell": .shell
        case "edit_file": .edit
        case "take_screenshot": .screenshot
        default: .other
        }
        let content: String
        var filePath: String?
        var timeout: Int?
        if kind == .shell {
            // Rust already prepared/validated the exact action. Interpret only its display fields.
            content = approval.call.arguments["command"].string ?? approval.description
            timeout = approval.call.arguments["timeout_seconds"].number.map(Int.init) ?? 120
        } else if kind == .edit {
            content = approval.details?["diff"].string ?? approval.description
            filePath = approval.details?["path"].string ?? approval.call.arguments["path"].string
        } else {
            content = approval.description
        }
        pendingApproval = Approval(id: approval.id, kind: kind, content: content,
                                   directory: URL(fileURLWithPath: approval.workspace),
                                   filePath: filePath, timeoutSeconds: timeout)
    }
    func resolveApproval(id: UUID, approved: Bool) {
        guard !resolving, pendingApproval?.id == id, let operationID, let resolve else { return }
        resolving = true
        Task {
            defer { resolving = false }
            do {
                try await resolve(operationID, id, approved)
                // Hide only an acknowledged decision, without fabricating a tool outcome.
                if pendingApproval?.id == id { pendingApproval = nil }
            } catch {
                // Reconciliation may retain this approval, remove it, or replace it.
                // A failed acknowledgement alone is never evidence it was resolved.
                reportError?(error.localizedDescription)
            }
        }
    }
}
