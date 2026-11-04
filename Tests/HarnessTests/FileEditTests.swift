import Foundation

@MainActor struct FileEditTests {
    func approvedEditsRejectStaleFilesAndPreserveMode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace.load(root)
        let file = root.appendingPathComponent("script")
        let original = Data("one\nold\nthree\n".utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let arguments: [String: String] = ["path": "script", "expected_revision": WorkspaceFiles.revision(original), "old_text": "old", "new_text": "new"]
        let call = ToolCall(id: "edit", name: "edit_file", arguments: String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self))
        let executor = ToolExecutor()
        let denied = Task { try await executor.execute(call, workspace: workspace) }
        try await waitForApproval(executor)
        try expect(executor.pendingApproval?.kind == .edit)
        try expect(executor.pendingApproval?.content.contains("-old\n+new") == true)
        try expect(try Data(contentsOf: file) == original)
        executor.resolveApproval(id: executor.pendingApproval!.id, approved: false)
        let denial = try await denied.value
        try expect(denial.contains("denied"))
        try expect(try Data(contentsOf: file) == original)

        let approved = Task { try await executor.execute(call, workspace: workspace) }
        try await waitForApproval(executor)
        executor.resolveApproval(id: executor.pendingApproval!.id, approved: true)
        let result = try await approved.value
        try expect(result.contains("Edited script"))
        try expect(try String(contentsOf: file, encoding: .utf8) == "one\nnew\nthree\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try expect(attributes[.posixPermissions] as? Int == 0o755)

        // Reusing a prior read revision must not even present an approval.
        let stale = try await executor.execute(call, workspace: workspace)
        try expect(stale.contains("File changed") && executor.pendingApproval == nil)
        try original.write(to: file)
        let pending = Task { try await executor.execute(call, workspace: workspace) }
        try await waitForApproval(executor)
        try "external edit".write(to: file, atomically: true, encoding: .utf8)
        executor.resolveApproval(id: executor.pendingApproval!.id, approved: true)
        let changed = try await pending.value
        try expect(changed.contains("File changed"))
        try expect(try String(contentsOf: file, encoding: .utf8) == "external edit")
    }

    func creationAndDiffBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try Workspace.load(root)
        let creation = try FileEdit.prepare(.init(path: "new.swift", expected_revision: "new", old_text: "", new_text: "hello\n"), workspace: workspace)
        try expect(creation.diff.contains("/dev/null") && creation.diff.contains("+hello"))
        _ = try creation.apply(workspace: workspace)
        try expectFailure { _ = try creation.apply(workspace: workspace) }
        let file = root.appendingPathComponent("new.swift")
        let data = try Data(contentsOf: file)
        let removeNewline = try FileEdit.prepare(.init(path: "new.swift", expected_revision: WorkspaceFiles.revision(data), old_text: "hello\n", new_text: "hello"), workspace: workspace)
        try expect(removeNewline.diff.contains("-hello\n+hello\n\\ No newline at end of file"))
        try expectFailure { _ = try FileEdit.prepare(.init(path: "../escape", expected_revision: "new", old_text: "", new_text: "no"), workspace: workspace) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: file)
        try expectFailure { _ = try FileEdit.prepare(.init(path: "linked", expected_revision: WorkspaceFiles.revision(data), old_text: "hello", new_text: "no"), workspace: workspace) }
        try Data("aaa".utf8).write(to: file)
        try expectFailure { _ = try FileEdit.prepare(.init(path: "new.swift", expected_revision: WorkspaceFiles.revision(Data("aaa".utf8)), old_text: "aa", new_text: "x"), workspace: workspace) }
    }

    private func waitForApproval(_ executor: ToolExecutor) async throws {
        for _ in 0..<200 {
            if executor.pendingApproval != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Edit approval did not appear")
    }
}
