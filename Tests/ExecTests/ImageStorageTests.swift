import Foundation

@MainActor struct ImageStorageTests {
    func migrationAndIntegrity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let image = ImageAttachment(name: "old.png", mediaType: "image/png", data: Data(repeating: 42, count: 4096))
        let call = ToolCall(id: "generated", name: "generate_image", arguments: "{}")
        let messages = [Message(role: .user, text: "image", images: [image]),
                        Message(role: .tool, text: "generated", toolResult: ToolResult(call: call, text: "generated", generatedImage: image))]
        let snapshot = SessionSnapshot(selectedModel: "test", messages: messages, history: messages, activeTurn: false)
        let id = UUID()
        // Simulate an existing inline save, without touching the user's store.
        let legacy = try JSONEncoder().encode(snapshot)
        try legacy.write(to: root.appendingPathComponent("\(id).json"))
        let loaded = try await sessions.load(id: id)!
        try expect(loaded.messages.first?.images.first?.data == image.data)
        try await sessions.save(loaded, id: id)
        let disk = try Data(contentsOf: root.appendingPathComponent("\(id).json"))
        try expect(disk.count < legacy.count / 2)
        try expect(!String(decoding: disk, as: UTF8.self).contains(image.data.base64EncodedString()))
        let restarted = SessionStore(directory: root)
        let restored = try await restarted.load(id: id)!
        try expect(restored.history.last?.toolResult?.generatedImage == image)
        let url = try await sessions.saveImage(image)
        try expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).count == 1)
        let files = ImageFiles(directory: url.deletingLastPathComponent())
        try expectFailure { _ = try files.load("../outside.png") }
        // Missing or tampered files fail explicitly, rather than silently losing context.
        try Data("damaged".utf8).write(to: url)
        try expectFailure { _ = try files.load(url.lastPathComponent) }
        try expectFailure { _ = try files.save(image.data, mediaType: image.mediaType) }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("\(id).json"))
        try expectFailure { _ = try files.load(url.lastPathComponent) }
        try FileManager.default.removeItem(at: url)
        do {
            _ = try await restarted.load(id: id)
            throw CheckFailure(description: "Missing image should fail restoration")
        } catch is ExecError {}
        try await deletion()
    }

    private func deletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessions = SessionStore(directory: root.appendingPathComponent("store"))
        let image = ImageAttachment(name: "generated.png", mediaType: "image/png", data: Data([1, 2, 3]))
        let other = ImageAttachment(name: "attached.jpg", mediaType: "image/jpeg", data: Data([4, 5, 6]))
        let call = ToolCall(id: "generated", name: "generate_image", arguments: "{}")
        let generated = Message(role: .tool, text: "generated", toolResult: ToolResult(call: call, text: "generated", generatedImage: image))
        let snapshot = SessionSnapshot(selectedModel: "test", messages: [generated],
                                       history: [Message(role: .user, text: "attached", images: [other])], activeTurn: false)
        let first = try await sessions.save(snapshot, id: UUID())
        let second = try await sessions.save(snapshot, id: UUID())
        let generatedURL = try await sessions.saveImage(image)
        let attachedURL = try await sessions.saveImage(other)
        let exported = root.appendingPathComponent("exported.png")
        try image.data.write(to: exported)
        try await sessions.delete(id: first)
        try expect(FileManager.default.fileExists(atPath: generatedURL.path))
        let retained = try await sessions.load(id: second)
        try expect(retained != nil)
        // Even a symlink at an asset name must never delete its outside target.
        try FileManager.default.removeItem(at: generatedURL)
        try FileManager.default.createSymbolicLink(at: generatedURL, withDestinationURL: exported)
        try await sessions.delete(id: second)
        try expect(!FileManager.default.fileExists(atPath: generatedURL.path))
        try expect(!FileManager.default.fileExists(atPath: attachedURL.path))
        try expect(try Data(contentsOf: exported) == image.data)
        try expect(try FileManager.default.contentsOfDirectory(atPath: attachedURL.deletingLastPathComponent().path).isEmpty)
    }
}
