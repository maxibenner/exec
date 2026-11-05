import Foundation

@MainActor struct CompactionTests {
    private let model = ChatModel(id: "test", name: "Test", contextWindow: 10_000)
    private let compacted: [[String: String]] = [["type": "compaction", "encrypted_content": "opaque-summary"]]

    private func provider(http: URLSession) throws -> OpenAIProvider {
        let credentials = MemoryCredentials()
        credentials.data = try JSONEncoder().encode(OpenAIAuthentication.Session(
            subject: "test", email: "test@example.com", accountID: "test",
            access: "test-access", refresh: "test-refresh", expires: Date().addingTimeInterval(3600)
        ))
        return try OpenAIProvider(authentication: OpenAIAuthentication(keychain: credentials, http: http), http: http)
    }

    private func state(_ history: [Message], tokens: Int) throws -> Data {
        let output = try JSONSerialization.data(withJSONObject: [
            ["type": "reasoning", "encrypted_content": "old-reasoning"],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "old answer"]]]
        ])
        return try JSONEncoder().encode(CodexConversationState(
            outputs: [history[0].id: output], measurement: .init(inputID: history[0].id, tokens: tokens)
        ))
    }

    func contextUsageReportsRestoredMeasurementsAndEstimates() throws {
        let http = HTTPStub.makeSession([])
        defer { http.invalidateAndCancel() }
        let provider = try provider(http: http)
        let history = [Message(role: .user, text: "Question"), Message(role: .assistant, text: "Answer")]
        try expect(provider.contextUsage([], model: model, instructions: "", tools: [])?.percent == 0)
        try expect(provider.contextUsage(history, model: ChatModel(id: "unknown", name: "Unknown"), instructions: "", tools: []) == nil)
        try provider.restoreConversationState(state(history, tokens: 2_500), history: history)
        let reported = provider.contextUsage(history, model: model, instructions: "", tools: [])
        try expect(reported == ContextUsage(tokens: 2_500, limit: 10_000, isEstimated: false))
        try expect(reported?.percent == 25)
        let appended = history + [Message(role: .user, text: "Next question")]
        let estimated = provider.contextUsage(appended, model: model, instructions: "", tools: [])
        try expect(estimated?.isEstimated == true && estimated!.tokens > 2_500)
        try expect(ContextUsage(tokens: 20_000, limit: 10_000, isEstimated: true).percent == 100)
        provider.clearConversationState()
        try expect(provider.contextUsage(history, model: model, instructions: "", tools: [])?.isEstimated == true)
        try expect(HTTPStub.state.requests.isEmpty)
    }

    func thresholdAndDurableOpaqueContinuation() async throws {
        let response = try JSONSerialization.data(withJSONObject: ["output": compacted])
        let final = Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Continued\"}]}],\"usage\":{\"input_tokens\":200,\"output_tokens\":10}}}\n\n".utf8)
        let http = HTTPStub.makeSession([.init(chunks: [response]), .init(chunks: [final])])
        defer { http.invalidateAndCancel() }
        let provider = try provider(http: http)
        let history = [Message(role: .user, text: "Remember this"), Message(role: .assistant, text: "old answer")]
        try provider.restoreConversationState(state(history, tokens: 9_499), history: history)
        let below = try await provider.compactIfNeeded(history, pending: [], model: model, instructions: "Keep instructions", tools: [])
        try expect(!below && HTTPStub.state.requests.isEmpty)
        try provider.restoreConversationState(state(history, tokens: 9_500), history: history)
        let changed = try await provider.compactIfNeeded(history, pending: [], model: model, instructions: "Keep instructions", tools: [])
        try expect(changed && HTTPStub.state.requests.count == 1)
        let request = HTTPStub.state.requests[0]
        try expect(request.url?.path == "/backend-api/codex/responses/compact")
        let body = try JSONSerialization.jsonObject(with: HTTPStub.body(of: request)) as! [String: Any]
        try expect(body["instructions"] as? String == CodexConnection.systemInstructions("Keep instructions"))
        try expect((body["input"] as? [[String: Any]])?.count == 3 && body["tools"] == nil)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let id = try await sessions.save(SessionSnapshot(identity: "test", selectedModel: "test", messages: history,
            history: history, providerState: provider.encodeConversationState(), activeTurn: false))
        let saved = try await sessions.load(id: id)!
        try expect(saved.messages.map(\.text) == history.map(\.text))
        let resumed = try provider.makeConversationProvider()
        try resumed.restoreConversationState(saved.providerState, history: saved.history)
        let next = Message(role: .user, text: "New pending question")
        for try await _ in resumed.send(history + [next], model: "test", effort: nil, instructions: "Keep instructions", tools: []) {}
        let nextBody = try JSONSerialization.jsonObject(with: HTTPStub.body(of: HTTPStub.state.requests[1])) as! [String: Any]
        let nextInput = nextBody["input"] as! [[String: Any]]
        try expect(nextInput.count == 2 && nextInput[0]["type"] as? String == "compaction")
        try expect(nextInput[1]["content"] as? String == next.text)
        let resumedState = try CodexConversationState.restore(resumed.encodeConversationState())
        try expect(resumedState.measurement?.tokens == 210)
        resumed.clearConversationState()
        try expect(try CodexConversationState.restore(provider.encodeConversationState()).prefix != nil)

        // A corrupt boundary must not replace valid provider state on restore.
        let bad = CodexConversationState(prefix: .init(throughID: UUID(), output: try JSONSerialization.data(withJSONObject: compacted)))
        try expectFailure { try provider.restoreConversationState(JSONEncoder().encode(bad), history: history) }
        try expect(try CodexConversationState.restore(provider.encodeConversationState()).prefix?.throughID == history.last?.id)
    }

    func failedAndCancelledCompactionKeepsOriginalContext() async throws {
        let history = [Message(role: .user, text: "Question"), Message(role: .assistant, text: "old answer")]
        for reply in [HTTPStub.Reply(status: 500), .init(chunks: [Data("{\"output\":[]}".utf8)])] {
            let http = HTTPStub.makeSession([reply])
            let provider = try provider(http: http)
            try provider.restoreConversationState(state(history, tokens: 9_500), history: history)
            do {
                _ = try await provider.compactIfNeeded(history, pending: [], model: model, instructions: "", tools: [])
                throw CheckFailure(description: "Invalid compaction succeeded")
            } catch is HarnessError {} catch is OpenAIHTTPError {}
            let remaining = try CodexConversationState.restore(provider.encodeConversationState())
            try expect(remaining.prefix == nil && remaining.measurement?.tokens == 9_500 && !remaining.outputs.isEmpty)
            try expect(HTTPStub.state.requests.count == 1) // No inference or compaction retry.
            http.invalidateAndCancel()
        }
        let http = HTTPStub.makeSession([.init(holdOpen: true)])
        defer { http.invalidateAndCancel() }
        let provider = try provider(http: http)
        try provider.restoreConversationState(state(history, tokens: 9_500), history: history)
        let task = Task { try await provider.compactIfNeeded(history, pending: [], model: model, instructions: "", tools: []) }
        for _ in 0..<400 {
            if HTTPStub.state.heldCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(HTTPStub.state.heldCount == 1)
        task.cancel()
        do { _ = try await task.value; throw CheckFailure(description: "Cancelled compaction succeeded") }
        catch is CancellationError {} catch let error as URLError { try expect(error.code == .cancelled) }
        let remaining = try CodexConversationState.restore(provider.encodeConversationState())
        try expect(remaining.prefix == nil && remaining.measurement?.tokens == 9_500)
        try expect(HTTPStub.state.requests.count == 1)
    }

    func estimatesLegacyStateAndClosedToolBoundaries() async throws {
        let history = [Message(role: .user, text: "Question"), Message(role: .assistant, text: "old answer")]
        let measured = try CodexConversationState.restore(state(history, tokens: 8_000))
        let pending = Message(role: .user, text: String(repeating: "x", count: 6_000))
        try expect(try measured.estimatedTokens(history + [pending], overhead: 0) >= 9_500)
        let legacy = try CodexConversationState.restore(JSONEncoder().encode(measured.outputs))
        try expect(legacy.prefix == nil && legacy.outputs == measured.outputs)
        let http = HTTPStub.makeSession([])
        defer { http.invalidateAndCancel() }
        let provider = try provider(http: http)
        var unfinished = history
        unfinished[1].toolCalls = [ToolCall(id: "pending", name: "shell", arguments: "{}")]
        try provider.restoreConversationState(state(unfinished, tokens: 9_500), history: unfinished)
        do {
            _ = try await provider.compactIfNeeded(unfinished, pending: [], model: model, instructions: "", tools: [])
            throw CheckFailure(description: "Compacted an unanswered call")
        } catch let error as HarnessError { try expect(error.message.contains("unresolved")) }
        do {
            _ = try await provider.compactIfNeeded(history, pending: [], model: ChatModel(id: "unknown", name: "Unknown"), instructions: "", tools: [])
            throw CheckFailure(description: "Ignored a missing model limit")
        } catch let error as HarnessError { try expect(error.message.contains("context limit")) }
        try expect(HTTPStub.state.requests.isEmpty)
        http.invalidateAndCancel()
        let catalogHTTP = HTTPStub.makeSession([.init(chunks: [Data("{\"models\":[{\"slug\":\"test\",\"context_window\":20000,\"effective_context_window_percent\":80}]}".utf8)])])
        defer { catalogHTTP.invalidateAndCancel() }
        let catalogProvider = try self.provider(http: catalogHTTP)
        let catalog = try await catalogProvider.models()
        try expect(catalog.first?.contextWindow == 16_000)
    }

    func checkpointFailurePreventsInferenceAfterCompaction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        let provider = FakeProvider()
        let store = ChatStore(provider: provider, sessions: SessionStore(directory: directory))
        store.restore()
        await store.waitUntilIdle()
        provider.compactionAction = {
            try FileManager.default.removeItem(at: directory)
            try Data("not a directory".utf8).write(to: directory)
            return true
        }
        store.draft = "Continue"
        store.send()
        await store.waitUntilIdle()
        try expect(provider.inputs.isEmpty && store.hasUnsavedChanges)
        try expect(store.error?.contains("Could not save") == true)
    }
}
