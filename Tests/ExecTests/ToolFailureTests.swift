import Foundation

@MainActor struct ToolFailureTests {
    private actor Fetch {
        let failure: any Error
        var paths: [String] = []
        init(failure: any Error) { self.failure = failure }

        func run(_ url: URL) throws -> String {
            paths.append(url.path)
            if url.path == "/failure" { throw failure }
            return "Previously fetched evidence"
        }
    }

    func preservesHistoryAndSafeFailureDetailsWithoutReplay() async throws {
        let failures: [any Error] = [
            ExecError("Content fetch failed (HTTP 403)."),
            URLError(.timedOut, userInfo: [
                NSLocalizedDescriptionKey: "secret raw response",
                NSURLErrorFailingURLErrorKey: URL(string: "https://example.com/?token=secret")!
            ])
        ]
        for failure in failures {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let sessions = SessionStore(directory: root)
            let provider = FakeProvider()
            let fetch = Fetch(failure: failure)
            let store = ChatStore(provider: provider, sessions: sessions, newConversation: true,
                                  fetchContent: { try await fetch.run($0) })
            store.selectedModel = "test"
            store.draft = "Earlier user instructions"
            store.send()
            await store.waitUntilIdle()
            let previous = store.messages

            let calls = ["success", "failure", "skipped"].map {
                ToolCall(id: $0, name: "fetch_content", arguments: "{\"url\":\"https://example.com/\($0)\"}")
            }
            provider.scripted = [[.text("I will inspect the pages.")] + calls.map(ChatEvent.toolCall) + [.completed]]
            store.draft = "Inspect these pages"
            store.send()
            await store.waitUntilIdle()
            try expect(store.error != nil && provider.inputs.count == 2)
            let attempted = await fetch.paths
            try expect(attempted == ["/success", "/failure"])

            let saved = try await sessions.load(id: store.currentSessionID)!
            try expect(!saved.activeTurn && saved.activeCallID == nil)
            try expect(Array(saved.history.prefix(previous.count)) == previous)
            try expect(saved.history[2].text == "Inspect these pages")
            try expect(saved.history[3].text == "I will inspect the pages.")
            let results = saved.history.compactMap(\.toolResult)
            try expect(results.map(\.call.id) == calls.map(\.id))
            try expect(results[0].text == "Previously fetched evidence")
            let detail = (failure as? ExecError)?.message ?? URLError(.timedOut).localizedDescription
            try expect(results[1].text.contains("Tool error: \(detail)"))
            try expect(results[1].text.contains("Do not retry without a new user request."))
            try expect(!results[1].text.contains("secret"))
            try expect(results[2].text == "Not executed: the turn was stopped.")
            try expect(saved.messages.compactMap(\.toolResult) == results)

            // Both a live follow-up and a restored session keep every earlier message
            // and explicit outcome, without resuming any failed/skipped operation.
            let restoredProvider = FakeProvider()
            let restored = ChatStore(provider: restoredProvider, sessions: sessions, newConversation: true,
                                     fetchContent: { try await fetch.run($0) })
            restored.openSession(store.currentSessionID!, loadModels: false)
            await restored.waitUntilIdle()
            try expect(restored.error == nil && restoredProvider.inputs.isEmpty)
            for (chat, model) in [(store, provider), (restored, restoredProvider)] {
                chat.draft = "Explain what happened; do not retry"
                chat.send()
                await chat.waitUntilIdle()
                try expect(chat.error == nil)
                let input = model.inputs.last!
                try expect(Array(input.dropLast()) == saved.history)
                let wire = try CodexConversationState().input(input)
                let outputs = wire.filter { $0["type"] as? String == "function_call_output" }
                try expect(outputs.compactMap { $0["output"] as? String } == results.map(\.text))
            }
            let finalAttempts = await fetch.paths
            try expect(finalAttempts == attempted)
        }
    }
}
