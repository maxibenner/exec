import Foundation

@MainActor struct SessionShellLogTests {
    func sessionOwnershipSurvivesRestartAndDeletesOnlyOwnedLogs() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        let sessions = SessionStore(directory: directory)
        let workspace = try Workspace.load(root)
        var ids: [UUID] = []
        var logs: [URL] = []
        for _ in 0..<2 {
            let provider = FakeProvider()
            provider.scripted = [[.toolCall(call("/usr/bin/yes x | /usr/bin/head -c 40000; printf 'FINAL ERROR' >&2; exit 7")), .completed]]
            let chat = ChatStore(provider: provider, sessions: sessions, newConversation: true, workspace: workspace)
            chat.selectedModel = "test"
            chat.draft = "Run the command"
            chat.send()
            await chat.waitUntilIdle()
            try expect(chat.error == nil && provider.inputs.count == 2)
            let result = chat.messages.compactMap(\.toolResult).first!
            try expect(result.text.contains("Exit code: 7") && result.text.contains("FINAL ERROR"))
            let url = try ShellOutputTests.logURL(in: result.text)
            let id = chat.currentSessionID!
            let owned = try await sessions.prepareShellLogDirectory(id: id)
            try expect(url.deletingLastPathComponent() == owned)
            let permissions = try FileManager.default.attributesOfItem(atPath: owned.path)
            try expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            ids.append(id); logs.append(url)
        }
        let restarted = SessionStore(directory: directory)
        let snapshot = try await restarted.load(id: ids[0])!
        try expect(snapshot.history.compactMap(\.toolResult).first?.text.contains(logs[0].path) == true)
        try expect(Data(contentsOf: logs[0]) == Data(contentsOf: logs[1]))
        try await restarted.delete(id: ids[0])
        try expect(!FileManager.default.fileExists(atPath: logs[0].deletingLastPathComponent().path))
        try expect(FileManager.default.fileExists(atPath: logs[1].path))
        do {
            _ = try await restarted.prepareShellLogDirectory(id: ids[0])
            throw CheckFailure(description: "Deleted session acquired new log storage")
        } catch is ExecError {}
        // A late capture with a stale path cannot recreate a deleted directory.
        let late = ShellOutputCapture(directory: logs[0].deletingLastPathComponent())
        late.append(Data(repeating: 65, count: 40_000))
        try expect(late.finish().contains("Full output log unavailable"))
        try expect(!FileManager.default.fileExists(atPath: logs[0].deletingLastPathComponent().path))
        try await restarted.delete(id: ids[1])
        try expect(!FileManager.default.fileExists(atPath: logs[1].deletingLastPathComponent().path))
    }

    func deletionFailureAndSymlinksStaySafe() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let id = try await sessions.save(SessionSnapshot(selectedModel: "test", messages: [], history: [], activeTurn: false))
        let logs = try await sessions.prepareShellLogDirectory(id: id)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let keep = outside.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: keep)
        try FileManager.default.removeItem(at: logs)
        try FileManager.default.createSymbolicLink(at: logs, withDestinationURL: outside)
        do {
            try await sessions.delete(id: id)
            throw CheckFailure(description: "Deletion followed a log directory symlink")
        } catch is ExecError {}
        let retained = try await sessions.load(id: id)
        try expect(retained != nil && FileManager.default.fileExists(atPath: keep.path))
        let blocked = ShellOutputCapture(directory: logs)
        blocked.append(Data(repeating: 65, count: 40_000))
        try expect(blocked.finish().contains("Full output log unavailable"))
        try expect(FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep"])

        try FileManager.default.removeItem(at: logs)
        _ = try await sessions.prepareShellLogDirectory(id: id)
        // Links inside the owned directory are unlinked, not followed.
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("linked.log"), withDestinationURL: keep)
        try await sessions.delete(id: id)
        try expect(!FileManager.default.fileExists(atPath: logs.path))
        try expect(String(contentsOf: keep, encoding: .utf8) == "keep")
    }

    func runningSessionCannotBeDeletedAndCancellationCleansUp() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let provider = FakeProvider()
        provider.scripted = [[.toolCall(call("/usr/bin/yes x | /usr/bin/head -c 40000; sleep 10")), .completed]]
        let chat = ChatStore(provider: provider, sessions: sessions, newConversation: true, workspace: try Workspace.load(root))
        defer { chat.stop() }
        chat.selectedModel = "test"
        chat.draft = "Run"
        chat.send()
        let id = chat.currentSessionID!
        var logs: URL?
        for _ in 0..<400 {
            if let directory = try? await sessions.prepareShellLogDirectory(id: id),
               !(try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty {
                logs = directory
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard let logs else { throw CheckFailure(description: "Shell did not start logging") }
        chat.deleteSession(id)
        try expect(chat.busy && FileManager.default.fileExists(atPath: logs.path))
        chat.stop()
        await chat.waitUntilIdle()
        try expect(FileManager.default.contentsOfDirectory(atPath: logs.path).isEmpty)
        chat.deleteSession(id)
        await chat.waitUntilIdle()
        try expect(chat.error == nil && !FileManager.default.fileExists(atPath: logs.path))
        let deleted = try await sessions.load(id: id)
        try expect(deleted == nil)
    }

    private func call(_ command: String) -> ToolCall {
        let arguments = try! JSONEncoder().encode(["command": command])
        return ToolCall(id: UUID().uuidString, name: "shell", arguments: String(decoding: arguments, as: UTF8.self))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return try Workspace.load(root).root
    }
}
