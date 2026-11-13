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
        var timeout: Int?
        if kind == .shell {
            // Rust already prepared/validated the exact action. Interpret only its display fields.
            content = approval.call.arguments["command"].string ?? approval.description
            timeout = approval.call.arguments["timeout_seconds"].number.map(Int.init) ?? 120
        } else if kind == .edit { content = approval.details?["diff"].string ?? approval.description }
        else { content = approval.description }
        pendingApproval = Approval(id: approval.id, kind: kind, content: content,
                                   directory: URL(fileURLWithPath: approval.workspace), timeoutSeconds: timeout)
    }
    func resolveApproval(id: UUID, approved: Bool, allowScreenshotsForSession: Bool = false) {
        guard !resolving, pendingApproval?.id == id, let operationID, let resolve else { return }
        guard !allowScreenshotsForSession else {
            reportError?("Session screenshot permission is not available in the current backend integration.")
            return
        }
        resolving = true
        Task {
            defer { resolving = false }
            do { try await resolve(operationID, id, approved) }
            catch { reportError?(error.localizedDescription) }
            // Hide the submitted decision locally, without fabricating a tool outcome.
            // An uncertain acknowledgement is not a denial; reopening reads backend state.
            if pendingApproval?.id == id { pendingApproval = nil }
        }
    }
}
