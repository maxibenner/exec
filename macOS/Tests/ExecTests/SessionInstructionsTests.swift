import Foundation

@MainActor struct SessionInstructionsTests {
    private func settle(_ library: ChatLibrary) async throws {
        for _ in 0..<400 {
            if !library.hasRunningOperations { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ExecError("Conversation did not settle")
    }

    func savesAndAppliesSystemPrompt() async throws {
        let suite = "SessionInstructionsTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(false, forKey: "generatedTitlesEnabled") // Inspect chat instructions, not title prompts.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "Keep project instructions.".write(to: project.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let provider = FakeProvider()
        let history = [Message(role: .user, text: "Earlier question"), Message(role: .assistant, text: "Earlier answer")]
        let snapshot = SessionSnapshot(identity: provider.conversationIdentity, workspace: try Workspace.load(project),
                                       selectedModel: "test", messages: history, history: history, activeTurn: false)
        let id = try await sessions.save(snapshot)
        // Reproduce an older on-disk conversation, including its removed field.
        let file = root.appendingPathComponent("sessions/\(id).json")
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        legacy["systemPrompt"] = "Obsolete conversation instructions."
        try JSONSerialization.data(withJSONObject: legacy).write(to: file, options: .atomic)
        preferences.set("Saved global instructions.", forKey: "systemPrompt")

        let library = try ChatLibrary(provider: provider, sessions: sessions, preferences: preferences)
        try expect(library.systemPrompt == "Saved global instructions.")
        library.systemPrompt = "Updated global instructions."
        try expect(preferences.string(forKey: "systemPrompt") == "Updated global instructions.")
        let reopened = try ChatLibrary(provider: FakeProvider(), sessions: sessions, preferences: preferences)
        try expect(reopened.systemPrompt == "Updated global instructions.")
        library.restore()
        try await settle(library)
        try expect(library.current.error == nil && library.current.messages.map(\.text) == history.map(\.text))
        library.draft = "Continue"
        library.send()
        try await settle(library)
        let instructions = provider.children.first?.instructions.last ?? ""
        try expect(library.current.error == nil && instructions.contains("Keep project instructions."))
        try expect(instructions.contains("fetch_content") && !instructions.contains("Obsolete"))
        try expect(instructions.contains("Updated global instructions."))
        library.systemPrompt = "New chat instructions."
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        try expect(saved["systemPrompt"] == nil)

        library.newConversation()
        try await settle(library)
        library.draft = "New conversation"
        library.send()
        try await settle(library)
        let fresh = provider.children.last?.instructions.last ?? ""
        try expect(library.current.error == nil && fresh.contains("Keep project instructions."))
        try expect(!fresh.contains("Obsolete") && fresh.contains("New chat instructions."))
        library.systemPrompt = ""
        library.draft = "Without custom instructions"
        library.send()
        try await settle(library)
        let cleared = provider.children.last?.instructions.last ?? ""
        try expect(!cleared.contains("New chat instructions.") && cleared.contains("Keep project instructions."))
    }
}
