import Foundation
import Observation

@MainActor @Observable final class ToolExecutor {
    struct Approval: Identifiable {
        let id = UUID()
        enum Kind { case shell, edit }
        let kind: Kind
        let content: String
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
                let approval = Approval(kind: .shell, content: command, directory: workspace.root)
                guard try await requestApproval(approval) else { return "User denied this command. It was not executed. Do not retry it without a new user request." }
                return try await background { try await ShellRunner.run(command, in: workspace.root) }
            }
            if call.name == "edit_file" {
                let arguments = try CodingTools.decode(FileEdit.Arguments.self, call)
                let edit = try await background { try FileEdit.prepare(arguments, workspace: workspace) }
                let approval = Approval(kind: .edit, content: edit.diff, directory: workspace.root)
                guard try await requestApproval(approval) else { return "User denied this edit. Nothing was written. Do not retry without a new user request." }
                return try await background { try edit.apply(workspace: workspace) }
            }
            return try await background { try CodingTools.readOnly(call, workspace: workspace) }
        } catch is CancellationError { throw CancellationError() }
        catch { return "Tool error: \(error.localizedDescription)" }
    }

    private func requestApproval(_ approval: Approval) async throws -> Bool {
        try Task.checkCancellation()
        guard pendingApproval == nil else { throw HarnessError("Another operation is awaiting approval.") }
        let approved = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingApproval = approval
                answer = continuation
            }
        } onCancel: {
            Task { @MainActor in self.resolveApproval(id: approval.id, approved: false) }
        }
        try Task.checkCancellation()
        return approved
    }

    private func background<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }
}
