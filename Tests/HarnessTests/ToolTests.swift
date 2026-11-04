import Foundation

@MainActor struct ToolTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try Workspace.load(root).root
    }

    func readToolsStayWithinWorkspace() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "outside needle".write(to: parent.appendingPathComponent("outside"), atomically: true, encoding: .utf8)
        try "first\nneedle café\nlast".write(to: root.appendingPathComponent("code.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: parent)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: parent.appendingPathComponent("outside"))
        let files = WorkspaceFiles(root: root)
        try expect(files.list(".").contains("code.swift"))
        try expect(files.read("code.swift", start: 2, end: 2).hasSuffix("2: needle café\n"))
        try expectFailure { _ = try files.read("../outside", start: 1, end: 2) }
        try expectFailure { _ = try files.read(parent.path + "/outside", start: 1, end: 2) }
        try expectFailure { _ = try files.read("escape/outside", start: 1, end: 2) }
        try expectFailure { _ = try files.read("linked", start: 1, end: 2) }
        try expectFailure { _ = try files.read("code.swift", start: 1, end: 401) }
        let search = try files.search(".", query: "needle")
        try expect(search.contains("code.swift:2: needle café") && !search.contains("outside needle"))
    }

    func shellOutputTimeoutAndCancellation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("HARNESS_TOOL_TEST_SECRET", "not-a-real-secret", 1)
        defer { unsetenv("HARNESS_TOOL_TEST_SECRET") }
        let environment = try await ShellRunner.run("printf '%s' \"${HARNESS_TOOL_TEST_SECRET-unset}\"", in: root)
        try expect(environment == "Exit code: 0\nunset")
        let output = try await ShellRunner.run("printf hello; printf problem >&2; exit 7", in: root)
        try expect(output.contains("Exit code: 7") && output.contains("helloproblem"))
        let large = try await ShellRunner.run("/usr/bin/yes x | /usr/bin/head -c 100000", in: root)
        try expect(large.contains("Output truncated") && large.utf8.count < 33_000)
        let timedOut = try await ShellRunner.run("(sleep 0.4; touch timeout-leak) & wait", in: root, timeout: .milliseconds(50))
        try expect(timedOut.contains("timed out"))
        let running = Task { try await ShellRunner.run("(sleep 0.4; touch cancellation-leak) & echo started > started; wait", in: root) }
        try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path) }
        running.cancel()
        do { _ = try await running.value; throw CheckFailure(description: "Command ignored cancellation") }
        catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(500))
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("timeout-leak").path))
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cancellation-leak").path))
    }

    func everyShellCommandRequiresApproval() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace.load(root)
        let executor = ToolExecutor()
        let call = ToolCall(id: "shell-1", name: "shell", arguments: #"{"command":"printf x >> effect"}"#)
        let denied = Task { try await executor.execute(call, workspace: workspace) }
        try await waitUntil { executor.pendingApproval != nil }
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
        executor.resolveApproval(id: UUID(), approved: true)
        try expect(executor.pendingApproval != nil)
        executor.resolveApproval(id: executor.pendingApproval!.id, approved: false)
        let denial = try await denied.value
        try expect(denial.contains("denied"))
        let approved = Task { try await executor.execute(call, workspace: workspace) }
        try await waitUntil { executor.pendingApproval != nil }
        executor.resolveApproval(id: executor.pendingApproval!.id, approved: true)
        let result = try await approved.value
        try expect(result.contains("Exit code: 0"))
        let cancelled = Task { try await executor.execute(call, workspace: workspace) }
        try await waitUntil { executor.pendingApproval != nil }
        let staleApproval = executor.pendingApproval!.id
        cancelled.cancel()
        executor.resolveApproval(id: staleApproval, approved: true) // Stop must win this race.
        do { _ = try await cancelled.value; throw CheckFailure(description: "Cancelled approval succeeded") }
        catch is CancellationError {}
        try expect(executor.pendingApproval == nil)
        try expect(try String(contentsOf: root.appendingPathComponent("effect"), encoding: .utf8) == "x")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out waiting for tool")
    }
}
