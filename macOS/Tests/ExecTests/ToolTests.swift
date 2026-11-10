import Foundation

@MainActor struct ToolTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try Workspace.load(root).root
    }

    func shellDescriptionIsDisplayMetadata() throws {
        let definition = CodingTools.definitions.first { $0.name == "shell" }
        try expect(definition?.parameters.contains { $0.name == "description" && $0.type == "string" } == true)
        let call = ToolCall(id: "description", name: "shell", arguments: #"{"command":"printf hello","description":"  Print a greeting  "}"#)
        try expect(CodingTools.shellDescription(call) == "Print a greeting")
        try expect(try CodingTools.shellArguments(call).command == "printf hello")
        let restored = try JSONDecoder().decode(ToolCall.self, from: JSONEncoder().encode(call))
        try expect(CodingTools.shellDescription(restored) == "Print a greeting")
        for metadata in ["", #", "description": "  ""#, #", "description": null"#, #", "description": 42"#] {
            let legacy = ToolCall(id: "legacy", name: "shell", arguments: "{\"command\":\"printf hello\"\(metadata)}")
            try expect(CodingTools.shellDescription(legacy) == nil)
            try expect(try CodingTools.shellArguments(legacy).command == "printf hello")
        }
        try expect(CodingTools.shellDescription(ToolCall(id: "other", name: "read_file", arguments: call.arguments)) == nil)
        let invalid = ToolCall(id: "invalid", name: "shell", arguments: #"{"command":"","description":"Print a greeting"}"#)
        try expectFailure { _ = try CodingTools.shellArguments(invalid).command }
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
        setenv("EXEC_TOOL_TEST_SECRET", "not-a-real-secret", 1)
        defer { unsetenv("EXEC_TOOL_TEST_SECRET") }
        let environment = try await ShellRunner.run("printf '%s' \"${EXEC_TOOL_TEST_SECRET-unset}\"", in: root)
        try expect(environment == "Exit code: 0\nunset")
        let output = try await ShellRunner.run("printf hello; printf problem >&2; exit 7", in: root)
        try expect(output.contains("Exit code: 7") && output.contains("helloproblem"))
        let large = try await ShellRunner.run("printf 'BUILD START\\n'; /usr/bin/yes x | /usr/bin/head -c 100000; printf 'FINAL FAILURE\\n' >&2; exit 9", in: root, logDirectory: root)
        let logURL = try ShellOutputTests.logURL(in: large)
        try expect(large.contains("Exit code: 9") && large.contains("Output truncated") && large.utf8.count < 34_000)
        try expect(large.contains("BUILD START\n") && large.contains("FINAL FAILURE\n"))
        let expected = Data(("BUILD START\n" + String(repeating: "x\n", count: 50_000) + "FINAL FAILURE\n").utf8)
        try expect(Data(contentsOf: logURL) == expected)
        // Recovery is a separate approved operation, not a replay of the failed build.
        let recovered = try await ShellRunner.run("/usr/bin/tail -n 1 '\(logURL.path)'", in: root)
        try expect(recovered == "Exit code: 0\nFINAL FAILURE\n")
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

    func shellTimeoutArgumentsAndExecution() async throws {
        func call(_ timeout: String?) -> ToolCall {
            let field = timeout.map { ",\"timeout_seconds\":\($0)" } ?? ""
            return ToolCall(id: UUID().uuidString, name: "shell", arguments: "{\"command\":\"printf x >> effect\"\(field)}")
        }
        for value in [nil, "null", "120"] as [String?] {
            try expect(CodingTools.shellArguments(call(value)).timeoutSeconds == 120)
        }
        for value in [1, 900] {
            try expect(CodingTools.shellArguments(call(String(value))).timeoutSeconds == value)
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace.load(root)
        let executor = ToolExecutor()
        executor.setAutoApproval(for: workspace.root)
        for value in ["0", "-1", "901", "1.5", "true", "\"900\"", "{}", "[]", "999999999999999999999999"] {
            let result = try await executor.execute(call(value), workspace: workspace)
            try expect(result.text.hasPrefix("Tool error:"))
            try expect(executor.pendingApproval == nil)
        }
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
        executor.setAutoApproval(for: nil)
        let extended = Task { try await executor.execute(call("900"), workspace: workspace) }
        try await waitUntil { executor.pendingApproval != nil }
        try expect(executor.pendingApproval?.timeoutSeconds == 900)
        try expect(executor.pendingApproval?.content == "printf x >> effect")
        executor.resolveApproval(id: executor.pendingApproval!.id, approved: true)
        let extendedResult = try await extended.value
        try expect(extendedResult.text.contains("Exit code: 0"))

        executor.setAutoApproval(for: workspace.root)
        let timed = ToolCall(id: "timeout", name: "shell",
            arguments: #"{"command":"printf x >> effect; (sleep 2; touch timeout-leak) & wait","timeout_seconds":1}"#)
        let result = try await executor.execute(timed, workspace: workspace)
        try expect(result.text.contains("timed out") && result.text.contains("Do not retry"))
        // An extended timeout must not delay Stop or leave ordinary children running.
        let cancelled = Task {
            try await executor.execute(ToolCall(id: "cancel", name: "shell",
                arguments: #"{"command":"(sleep 2; touch cancellation-leak) & echo started > started; wait","timeout_seconds":900}"#), workspace: workspace)
        }
        try await waitUntil { FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw CheckFailure(description: "Extended command ignored Stop") }
        catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(2200))
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("timeout-leak").path))
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cancellation-leak").path))
        try expect(try String(contentsOf: root.appendingPathComponent("effect"), encoding: .utf8) == "xx")
    }

    func everyShellCommandRequiresApproval() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace.load(root)
        let executor = ToolExecutor()
        let call = ToolCall(id: "shell-1", name: "shell", arguments: #"{"command":"printf x >> effect","description":"Append a marker"}"#)
        let denied = Task { try await executor.execute(call, workspace: workspace) }
        try await waitUntil { executor.pendingApproval != nil }
        try expect(executor.pendingApproval?.timeoutSeconds == 120)
        try expect(executor.pendingApproval?.content == "printf x >> effect")
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
        executor.resolveApproval(id: UUID(), approved: true)
        try expect(executor.pendingApproval != nil)
        executor.resolveApproval(id: executor.pendingApproval!.id, approved: false)
        let denial = try await denied.value
        try expect(denial.text.contains("denied"))
        let approved = Task { try await executor.execute(call, workspace: workspace) }
        try await waitUntil { executor.pendingApproval != nil }
        executor.resolveApproval(id: executor.pendingApproval!.id, approved: true)
        let result = try await approved.value
        try expect(result.text.contains("Exit code: 0"))
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

    func autoApprovalIsScopedAndRevocable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace.load(root)
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherWorkspace = try Workspace.load(other)
        let executor = ToolExecutor()
        let call = ToolCall(id: "auto", name: "shell", arguments: #"{"command":"printf x >> effect"}"#)
        try expect(executor.autoApprovedDirectory == nil)
        executor.setAutoApproval(for: workspace.root)
        let first = try await executor.execute(call, workspace: workspace)
        let second = try await executor.execute(call, workspace: workspace)
        try expect(first.text.contains("Exit code: 0") && second.text.contains("Exit code: 0"))
        try expect(executor.pendingApproval == nil)
        let scoped = Task { try await executor.execute(call, workspace: otherWorkspace) }
        try await waitUntil { executor.pendingApproval != nil }
        executor.resolveApproval(id: executor.pendingApproval!.id, approved: false)
        _ = try await scoped.value
        try expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent("effect").path))
        executor.setAutoApproval(for: nil)
        let manual = Task { try await executor.execute(call, workspace: workspace) }
        try await waitUntil { executor.pendingApproval != nil }
        manual.cancel()
        do { _ = try await manual.value; throw CheckFailure(description: "Cancelled approval ran") }
        catch is CancellationError {}
        try expect(try String(contentsOf: root.appendingPathComponent("effect"), encoding: .utf8) == "xx")
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out waiting for tool")
    }
}
