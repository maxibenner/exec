import Foundation

@MainActor struct SystemPromptTests {
    func persistsAndSnapshots() async throws {
        let suite = "SystemPromptTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: sessions, preferences: preferences)
        library.restore()
        while library.hasRunningOperations { try await Task.sleep(for: .milliseconds(10)) }
        library.systemPrompt = "Respond in Spanish."
        try expect(library.current.systemPrompt.isEmpty)
        library.newConversation()
        while library.hasRunningOperations { try await Task.sleep(for: .milliseconds(10)) }
        try expect(library.current.systemPrompt == "Respond in Spanish.")
        library.systemPrompt = "Respond in French."
        library.draft = "Hello"
        library.send()
        while library.hasRunningOperations { try await Task.sleep(for: .milliseconds(10)) }
        try expect(provider.children.last?.instructions.last?.contains("Respond in Spanish.") == true)
        let saved = try await sessions.load(id: library.currentSessionID!)
        try expect(saved?.systemPrompt == "Respond in Spanish.")
        let reopened = try ChatLibrary(provider: FakeProvider(), sessions: sessions, preferences: preferences)
        try expect(reopened.systemPrompt == "Respond in French.")
        reopened.restore()
        while reopened.hasRunningOperations { try await Task.sleep(for: .milliseconds(10)) }
        try expect(reopened.current.systemPrompt == "Respond in Spanish.")
        library.systemPrompt = ""
        try expect(preferences.string(forKey: "systemPrompt") == "")
    }
}
