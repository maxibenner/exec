import Foundation
import Observation

@MainActor @Observable final class ToolExecutor {
    struct Approval: Identifiable {
        let id = UUID()
        let command: String
        let directory: URL
    }
    private(set) var pendingApproval: Approval?
    private var answer: CheckedContinuation<Bool, Never>?

    func resolveApproval(id: UUID, approved: Bool) {
        guard pendingApproval?.id == id else { return }
        pendingApproval = nil
        let continuation = answer
        answer = nil
        continuation?.resume(returning: approved)
    }

    func execute(_ call: ToolCall, workspace: Workspace?) async throws -> String {
        try Task.checkCancellation()
        guard let workspace else { return "Error: select a workspace before using tools." }
        do {
            if call.name == "shell" {
                let command = try CodingTools.command(call)
                guard pendingApproval == nil else { throw HarnessError("Another command is awaiting approval.") }
                let approval = Approval(command: command, directory: workspace.root)
                let approved = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        pendingApproval = approval
                        answer = continuation
                    }
                } onCancel: {
                    Task { @MainActor in self.resolveApproval(id: approval.id, approved: false) }
                }
                try Task.checkCancellation()
                guard approved else { return "User denied this command. It was not executed. Do not retry it without a new user request." }
                return try await background { try await ShellRunner.run(command, in: workspace.root) }
            }
            return try await background { try CodingTools.readOnly(call, workspace: workspace) }
        } catch is CancellationError { throw CancellationError() }
        catch { return "Tool error: \(error.localizedDescription)" }
    }

    private func background(_ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }
}
