import Foundation
import Observation

struct ToolApprovalDenied: ContextSafeError {
    let errorDescription: String?
}

@MainActor @Observable final class ToolExecutor {
    struct Approval: Identifiable {
        let id = UUID()
        enum Kind { case shell, edit, screenshot }
        let kind: Kind
        let content: String
        let directory: URL
        var timeoutSeconds: Int? = nil
    }
    private(set) var pendingApproval: Approval? {
        didSet { approvalDidChange?(pendingApproval != nil) }
    }
    var approvalDidChange: ((Bool) -> Void)?
    private(set) var autoApprovedDirectory: URL?
    private(set) var screenshotsAllowedForSession = false

    func resetScreenshotPermission() {
        screenshotsAllowedForSession = false
    }
    struct InputArrived: Error {}
    static let supersededByInput = "Not executed: new user input arrived. Reconsider this operation using the new instructions."
    var shouldYieldForInput: (() -> Bool)?
    private enum Decision { case approved, denied, superseded }
    private var answer: CheckedContinuation<Decision, Never>?

    func withdrawApprovalForInput() {
        guard pendingApproval != nil else { return }
        pendingApproval = nil
        let continuation = answer
        answer = nil
        continuation?.resume(returning: .superseded)
    }

    func setAutoApproval(for directory: URL?) {
        autoApprovedDirectory = directory
        if let directory, let pending = pendingApproval,
           pending.kind == .screenshot || pending.directory == directory {
            resolveApproval(id: pending.id, approved: true)
        }
    }

    func resolveApproval(id: UUID, approved: Bool, allowScreenshotsForSession: Bool = false) {
        guard let pending = pendingApproval, pending.id == id else { return }
        if approved, allowScreenshotsForSession, pending.kind == .screenshot {
            screenshotsAllowedForSession = true
        }
        pendingApproval = nil
        let continuation = answer
        answer = nil
        continuation?.resume(returning: approved ? .approved : .denied)
    }

    func execute(_ call: ToolCall, workspace: Workspace?, shellLogDirectory: URL? = nil) async throws -> ToolResult {
        try Task.checkCancellation()
        guard let workspace else { return ToolResult(call: call, text: "Error: select a workspace before using tools.") }
        do {
            if call.name == "shell" {
                let arguments = try CodingTools.shellArguments(call)
                let approval = Approval(kind: .shell, content: arguments.command, directory: workspace.root,
                                        timeoutSeconds: arguments.timeoutSeconds)
                guard try await requestApproval(approval) else {
                    return ToolResult(call: call, text: "User denied this command. It was not executed. Do not retry it without a new user request.")
                }
                return ToolResult(call: call, text: try await background {
                    try await ShellRunner.run(arguments.command, in: workspace.root,
                                              timeout: .seconds(arguments.timeoutSeconds), logDirectory: shellLogDirectory)
                })
            }
            if call.name == "edit_file" {
                let arguments = try CodingTools.decode(FileEdit.Arguments.self, call)
                let edit = try await background { try FileEdit.prepare(arguments, workspace: workspace) }
                let approval = Approval(kind: .edit, content: edit.diff, directory: workspace.root)
                guard try await requestApproval(approval) else {
                    return ToolResult(call: call, text: "User denied this edit. Nothing was written. Do not retry without a new user request.")
                }
                let text = try await background { try await FileEditWriter.shared.apply(edit, workspace: workspace) }
                return ToolResult(call: call, text: text, edit: .init(path: edit.path, diff: edit.diff))
            }
            return ToolResult(call: call, text: try await background { try CodingTools.readOnly(call, workspace: workspace) })
        } catch is CancellationError { throw CancellationError() }
        catch is InputArrived { throw InputArrived() }
        catch { return ToolResult(call: call, text: "Tool error: \(error.localizedDescription)") }
    }

    func approveScreenshot(_ request: ScreenshotTool.Request) async throws -> Bool {
        try await requestApproval(Approval(kind: .screenshot,
            content: "\(request.summary). Images and window titles are sent to the connected model and saved in this conversation. They may include sensitive information.",
            directory: URL(fileURLWithPath: "/")))
    }

    private func requestApproval(_ approval: Approval) async throws -> Bool {
        try Task.checkCancellation()
        guard shouldYieldForInput?() != true else { throw InputArrived() }
        guard pendingApproval == nil else { throw ExecError("Another operation is awaiting approval.") }
        if approval.kind == .screenshot {
            if autoApprovedDirectory != nil || screenshotsAllowedForSession { return true }
        } else if autoApprovedDirectory == approval.directory { return true }
        let approved = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingApproval = approval
                answer = continuation
            }
        } onCancel: {
            Task { @MainActor in self.resolveApproval(id: approval.id, approved: false) }
        }
        try Task.checkCancellation()
        if approved == .superseded { throw InputArrived() }
        // Input can arrive after an approval is resolved but before execution resumes.
        if approved == .approved, shouldYieldForInput?() == true { throw InputArrived() }
        return approved == .approved
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
