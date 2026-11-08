import Foundation

struct WorkspaceTests {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(condition())
    }

    @MainActor func refreshesInstructionsOnFirstSend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("AGENTS.md")
        try "Old instructions".write(to: file, atomically: true, encoding: .utf8)
        let snapshot = try Workspace.load(root)
        let provider = FakeProvider()
        let store = ChatStore(provider: provider)
        store.selectedModel = "test"
        try store.setInitialWorkspace(snapshot)
        try "Fresh instructions".write(to: file, atomically: true, encoding: .utf8)
        store.draft = "First"; store.send()
        try await wait { !store.busy }
        try expect(provider.instructions.count == 1)
        try expect(provider.instructions[0].contains("Fresh instructions"))
        try "Later instructions".write(to: file, atomically: true, encoding: .utf8)
        store.draft = "Second"; store.send()
        try await wait { !store.busy }
        try expect(provider.instructions.count == 2)
        try expect(provider.instructions[1].contains("Fresh instructions"))

        let nextProvider = FakeProvider()
        let next = ChatStore(provider: nextProvider)
        next.selectedModel = "test"
        try next.setInitialWorkspace(snapshot)
        try Data([0xFF]).write(to: file)
        next.draft = "Keep queued"; next.send()
        try await wait { !next.busy }
        try expect(next.error != nil && nextProvider.instructions.isEmpty)
        try expect(next.messages.map(\.text) == ["Keep queued"] && next.pendingInput.map(\.text) == ["Keep queued"])
        try FileManager.default.removeItem(at: file)
        next.draft = "Continue"; next.send()
        try await wait { !next.busy }
        try expect(nextProvider.instructions.count == 1)
        try expect(!nextProvider.instructions[0].contains("Old instructions"))
        try expect(next.workspace?.instructions == nil)
    }

    func loadsOnlyRootInstructionsAndRejectsUnsafeFiles() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("AGENTS.md")
        try "Parent instructions must not be loaded".write(to: outside, atomically: true, encoding: .utf8)
        try expect(Workspace.load(root).instructions == nil)
        let file = root.appendingPathComponent("AGENTS.md")
        try "Use Swift. Keep café names intact.".write(to: file, atomically: true, encoding: .utf8)
        let workspace = try Workspace.load(root)
        try expect(workspace.instructions == "Use Swift. Keep café names intact.")
        try expect(workspace.modelInstructions.contains(workspace.root.path))
        try expect(!workspace.modelInstructions.contains("Parent instructions"))

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        try expectFailure { _ = try Workspace.load(root) }
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 65, count: Workspace.instructionByteLimit + 1).write(to: file)
        try expectFailure { _ = try Workspace.load(root) }
        try Data([0xFF, 0xFE]).write(to: file)
        try expectFailure { _ = try Workspace.load(root) }
        try expectFailure { _ = try Workspace.load(file) }
    }
}
