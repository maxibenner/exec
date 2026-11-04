import Foundation

struct WorkspaceTests {
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
