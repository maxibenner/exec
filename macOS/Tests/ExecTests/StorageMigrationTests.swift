import Foundation

@MainActor struct StorageMigrationTests {
    func migratesAndProtectsExistingData() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Harness")
        let current = root.appendingPathComponent("Exec")
        let fresh = try SessionStore.applicationStore(in: root)
        try expect(fresh.directory.lastPathComponent == "Exec")
        let old = SessionStore(directory: legacy)
        let message = Message(role: .user, text: "Keep this conversation")
        let snapshot = SessionSnapshot(identity: nil, workspace: nil, selectedModel: "test",
                                       messages: [message], history: [message], providerState: nil, activeTurn: false)
        let id = try await old.save(snapshot)
        let images = legacy.appendingPathComponent("images")
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        let bytes = Data([1, 2, 3])
        try bytes.write(to: images.appendingPathComponent("retained.png"))
        let permissions = try fm.attributesOfItem(atPath: legacy.path)[.posixPermissions] as? Int
        let migrated = try SessionStore.applicationStore(in: root)
        let restored = try await migrated.load()
        try expect(restored?.messages.first?.id == message.id)
        let selected = try await migrated.preferredID(identity: nil)
        try expect(selected == id)
        try expect(!fm.fileExists(atPath: legacy.path))
        try expect(try Data(contentsOf: current.appendingPathComponent("images/retained.png")) == bytes)
        try expect(try fm.attributesOfItem(atPath: current.path)[.posixPermissions] as? Int == permissions)
        let reopened = try SessionStore.applicationStore(in: root)
        let again = try await reopened.load()
        try expect(again?.messages.first?.id == message.id)

        // Conflicts and symlinks must fail without changing either location.
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try expectFailure { _ = try SessionStore.applicationStore(in: root) }
        try expect(fm.fileExists(atPath: current.appendingPathComponent("\(id).json").path))
        try fm.removeItem(at: legacy)
        try fm.createSymbolicLink(at: legacy, withDestinationURL: current)
        try expectFailure { _ = try SessionStore.applicationStore(in: root) }
        try fm.removeItem(at: legacy)
        try fm.removeItem(at: current)
        try fm.createSymbolicLink(at: current, withDestinationURL: legacy)
        try expectFailure { _ = try SessionStore.applicationStore(in: root) }
    }
}
