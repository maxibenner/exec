import Foundation

@MainActor struct SessionTitleTests {
    func updatesPersistWithoutChangingChatContext() async throws {
        let suite = "ExecTitleTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let provider = FakeProvider()
        let sessions = SessionStore(directory: root)
        let library = try ChatLibrary(provider: provider, sessions: sessions, preferences: preferences)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        try expect(!library.generatedTitlesEnabled)
        library.generatedTitlesEnabled = true
        library.titleModel = "test"
        let firstMessage = String(repeating: "Include vegetables, flowers, and paths with enough space to grow. ", count: 40)
            + "Plan a garden."
        library.draft = firstMessage
        library.send()
        try await wait { !library.hasRunningOperations }
        let id = library.currentSessionID!
        try expect(library.sessionList.first?.title == "Hello world")
        let saved = try await sessions.load(id: id)
        try expect(saved?.title == "Hello world")
        let chat = provider.children[0]
        let title = provider.children[1]
        try expect(chat.inputs[0].map(\.text) == [firstMessage])
        try expect(title.inputs.count == 1 && title.inputs[0].count == 1)
        let fields = try JSONDecoder().decode([String: String].self, from: Data(title.inputs[0][0].text.utf8))
        // The first request must not treat the truncated display fallback as an established title.
        try expect(fields == ["current_title": "", "latest_user_message": firstMessage])
        library.draft = "Add tomatoes"
        library.send()
        try await wait { !library.hasRunningOperations }
        let next = provider.children[2]
        let nextFields = try JSONDecoder().decode([String: String].self, from: Data(next.inputs[0][0].text.utf8))
        try expect(nextFields == ["current_title": "Hello world", "latest_user_message": "Add tomatoes"])
        try expect(chat.inputs.last?.last?.text == "Add tomatoes")
        library.generatedTitlesEnabled = false
        library.draft = "No title request"
        library.send()
        try await wait { !library.hasRunningOperations }
        try expect(provider.children.count == 3)
        let reopened = try ChatLibrary(provider: FakeProvider(), sessions: sessions, preferences: preferences)
        try expect(!reopened.generatedTitlesEnabled && reopened.titleModel == "test")
    }

    func rejectsFailedAndCancelledGeneration() async throws {
        let provider = TitleTestProvider()
        provider.events = [.text("Partial")]
        do {
            _ = try await SessionTitleGenerator.generate(provider: provider, model: "title-model", title: "Old", message: "New")
            throw CheckFailure(description: "Accepted incomplete title")
        } catch is ExecError {}
        try expect(provider.calls == 1)
        provider.events = [.text("First"), .textSnapshot("Final title"), .completed]
        let title = try await SessionTitleGenerator.generate(provider: provider, model: "title-model", title: "Old", message: "New")
        try expect(title == "Final title" && provider.calls == 2)
        let task = Task {
            try await SessionTitleGenerator.generate(provider: provider, model: "title-model", title: "Old", message: "New")
        }
        task.cancel()
        do {
            _ = try await task.value
            throw CheckFailure(description: "Accepted cancelled title")
        } catch is CancellationError {}
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Title operations did not settle")
    }
}

@MainActor private final class TitleTestProvider: ChatProvider {
    let connectionTitle = "Test"
    let account: String? = "isolated-test"
    var events: [ChatEvent] = []
    var calls = 0
    func makeConversationProvider() throws -> any ChatProvider { self }
    func connect() async throws {}
    func disconnect() async throws {}
    func models() async throws -> [ChatModel] { [] }
    func send(_ messages: [Message], model: String, effort: String?, instructions: String, tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error> {
        calls += 1
        return AsyncThrowingStream { continuation in
            do {
                try expect(model == "title-model" && tools.isEmpty && messages.count == 1)
                for event in events { continuation.yield(event) }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}
