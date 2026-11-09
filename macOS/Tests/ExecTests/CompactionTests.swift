import Foundation

@MainActor struct CompactionTests {
    private let model = ChatModel(id: "test", name: "Test", contextWindow: 10_000)
    private let compacted: [[String: String]] = [["type": "compaction", "encrypted_content": "opaque-summary"]]

    private func stream(_ output: [[String: Any]], completed: Bool = true, tokens: Int? = nil) throws -> Data {
        var events: [[String: Any]] = output.enumerated().map { index, item in
            ["type": "response.output_item.done", "output_index": index, "item": item]
        }
        if completed {
            var response: [String: Any] = ["status": "completed", "output": []]
            if let tokens { response["usage"] = ["input_tokens": tokens, "output_tokens": 0] }
            events.append(["type": "response.completed", "response": response])
        }
        return try events.reduce(into: Data()) { data, event in
            data.append(Data("data: ".utf8))
            data.append(try JSONSerialization.data(withJSONObject: event))
            data.append(Data("\n\n".utf8))
        }
    }

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

    func contextUsageReportsOnlyMatchingMeasurements() async throws {
        let http = HTTPStub.makeSession([])
        defer { http.invalidateAndCancel() }
        let provider = try provider(http: http)
        let history = [Message(role: .user, text: "Question"), Message(role: .assistant, text: "Answer")]
        try expect(provider.contextUsage([], model: model, instructions: "", tools: []) == nil)
        try expect(provider.contextUsage(history, model: ChatModel(id: "unknown", name: "Unknown"), instructions: "", tools: []) == nil)
        try provider.restoreConversationState(state(history, tokens: 2_500), history: history)
        let reported = provider.contextUsage(history, model: model, instructions: "", tools: [])
        try expect(reported == ContextUsage(tokens: 2_500, limit: 10_000))
        try expect(reported?.percent == 25)
        let appended = history + [Message(role: .user, text: "Next question")]
        try expect(provider.contextUsage(appended, model: model, instructions: "", tools: []) == reported)
        let streaming = appended + [Message(role: .assistant, text: "Partial response")]
        try expect(provider.contextUsage(streaming, model: model, instructions: "", tools: []) == reported)
        let saved = try CodexConversationState.restore(state(history, tokens: 2_500))
        try expect(saved.reportedTokens(appended) == nil)
        // A completed transport can publish accounting before history commits the reply.
        var updating = CodexConversationState(
            measurement: .init(inputID: appended.last!.id, tokens: 3_000),
            displayMeasurement: saved.measurement)
        try expect(updating.lastReportedTokens(appended) == 2_500)
        try expect(updating.lastReportedTokens(streaming) == 3_000)
        var cancelled = streaming
        cancelled[cancelled.count - 1].status = .interrupted
        try expect(updating.lastReportedTokens(cancelled) == 2_500)
        updating.measurement = nil // A response without accounting must not erase the footer.
        try expect(updating.lastReportedTokens(streaming) == 2_500)
        try expect(updating.reportedTokens(streaming) == nil)
        try expect(updating.lastReportedTokens([]) == nil)
        let compactedDisplay = CodexConversationState(
            prefix: .init(throughID: history.last!.id, output: try JSONSerialization.data(withJSONObject: compacted)),
            displayMeasurement: saved.measurement)
        let restoredDisplay = try CodexConversationState.restore(JSONEncoder().encode(compactedDisplay))
        try expect(restoredDisplay.lastReportedTokens(history) == nil)
        try expect(restoredDisplay.reportedTokens(history) == nil)
        try expect(provider.contextUsage(Array(appended.dropFirst()), model: model, instructions: "", tools: []) == nil)
        var interrupted = history
        interrupted[1].status = .interrupted
        try expect(provider.contextUsage(interrupted + [appended.last!], model: model, instructions: "", tools: []) == nil)
        try expect(ContextUsage(tokens: 20_000, limit: 10_000).percent == 100)
        provider.clearConversationState()
        try expect(provider.contextUsage(history, model: model, instructions: "", tools: []) == nil)
        try expect(HTTPStub.state.requests.isEmpty)

        let withoutUsage = Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Next answer\"}]}]}}\n\n".utf8)
        let responseHTTP = HTTPStub.makeSession([.init(chunks: [withoutUsage])])
        defer { responseHTTP.invalidateAndCancel() }
        let responding = try self.provider(http: responseHTTP)
        try responding.restoreConversationState(state(history, tokens: 2_500), history: history)
        for try await _ in responding.send(appended, model: model.id) {
            try expect(responding.contextUsage(appended, model: model, instructions: "", tools: []) == reported)
        }
        try expect(responding.contextUsage(streaming, model: model, instructions: "", tools: []) == reported)
    }

    func thresholdAndDurableOpaqueContinuation() async throws {
        let response = try stream(compacted + [["type": "function_call", "call_id": "ignored", "name": "shell", "arguments": "{}"]], tokens: 9_800)
        let final = Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Continued\"}]}],\"usage\":{\"input_tokens\":200,\"output_tokens\":10}}}\n\n".utf8)
        let http = HTTPStub.makeSession([.init(chunks: [response]), .init(chunks: [final])])
        defer { http.invalidateAndCancel() }
        let provider = try provider(http: http)
        let history = [Message(role: .user, text: "Remember this"), Message(role: .assistant, text: "old answer")]
        try provider.restoreConversationState(state(history, tokens: 9_499), history: history)
        var starts = 0
        let below = try await provider.compactIfNeeded(history, pending: [], model: model, instructions: "Keep instructions", tools: [],
                                                       willCompact: { starts += 1 })
        try expect(!below && HTTPStub.state.requests.isEmpty && starts == 0)
        try provider.restoreConversationState(state(history, tokens: 9_500), history: history)
        do {
            _ = try await provider.compactIfNeeded(history, pending: [], model: model, instructions: "", tools: [],
                willCompact: { throw ExecError("Activity checkpoint failed") })
            throw CheckFailure(description: "Ignored a failed activity checkpoint")
        } catch let error as ExecError { try expect(error.message == "Activity checkpoint failed") }
        try expect(HTTPStub.state.requests.isEmpty)
        let changed = try await provider.compactIfNeeded(history, pending: [], model: model, instructions: "Keep instructions", tools: [],
                                                         willCompact: { starts += 1 })
        try expect(changed && HTTPStub.state.requests.count == 1 && starts == 1)
        // Compaction accounting is not the size of the replacement context.
        try expect(provider.contextUsage(history, model: model, instructions: "", tools: []) == nil)
        let request = HTTPStub.state.requests[0]
        try expect(request.url?.path == "/backend-api/codex/responses")
        try expect(request.httpMethod == "POST")
        try expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        try expect(request.value(forHTTPHeaderField: "session-id") == history[0].id.uuidString)
        let body = try JSONSerialization.jsonObject(with: HTTPStub.body(of: request)) as! [String: Any]
        try expect(body["instructions"] as? String == CodexConnection.systemInstructions("Keep instructions"))
        try expect(body["stream"] as? Bool == true && body["store"] as? Bool == false)
        let input = body["input"] as! [[String: Any]]
        try expect(input.count == 4 && body["tools"] == nil)
        try expect(input.last?["type"] as? String == "compaction_trigger")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let id = try await sessions.save(SessionSnapshot(identity: "test", selectedModel: "test", messages: history,
            history: history, providerState: provider.encodeConversationState(), activeTurn: false))
        let saved = try await sessions.load(id: id)!
        try expect(saved.messages.map(\.text) == history.map(\.text))
        let resumed = try provider.makeConversationProvider()
        try resumed.restoreConversationState(saved.providerState, history: saved.history)
        try expect(resumed.contextUsage(history, model: model, instructions: "", tools: []) == nil)
        let next = Message(role: .user, text: "New pending question")
        for try await _ in resumed.send(history + [next], model: "test", effort: nil, instructions: "Keep instructions", tools: []) {}
        let nextBody = try JSONSerialization.jsonObject(with: HTTPStub.body(of: HTTPStub.state.requests[1])) as! [String: Any]
        let nextInput = nextBody["input"] as! [[String: Any]]
        try expect(nextInput.count == 2 && nextInput[0]["type"] as? String == "compaction")
        try expect(nextInput[1]["content"] as? String == next.text)
        let resumedState = try CodexConversationState.restore(resumed.encodeConversationState())
        try expect(resumedState.measurement?.tokens == 210)
        try expect(resumed.contextUsage(history + [next, Message(role: .assistant, text: "Continued")],
                                        model: model, instructions: "", tools: [])?.tokens == 210)
        try expect(resumedState.requestUsage?.map(\.kind) == [.compaction, .main])
        try expect(resumedState.requestUsage?.last?.usage?.cachedInputTokens == nil)
        resumed.clearConversationState()
        try expect(try CodexConversationState.restore(provider.encodeConversationState()).prefix != nil)

        // A corrupt boundary must not replace valid provider state on restore.
        let bad = CodexConversationState(prefix: .init(throughID: UUID(), output: try JSONSerialization.data(withJSONObject: compacted)))
        try expectFailure { try provider.restoreConversationState(JSONEncoder().encode(bad), history: history) }
        try expect(try CodexConversationState.restore(provider.encodeConversationState()).prefix?.throughID == history.last?.id)
    }

    func failedAndCancelledCompactionKeepsOriginalContext() async throws {
        let history = [Message(role: .user, text: "Question"), Message(role: .assistant, text: "old answer")]
        let replies: [HTTPStub.Reply] = [
            .init(status: 404), .init(status: 500),
            .init(chunks: [try stream([])]),
            .init(chunks: [try stream([["type": "compaction", "encrypted_content": ""]])]),
            .init(chunks: [try stream(compacted + compacted)]),
            .init(chunks: [try stream(compacted, completed: false)]),
            .init(chunks: [try stream(compacted, completed: false),
                           Data("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"server_error\"}}}\n\n".utf8)])
        ]
        for reply in replies {
            let http = HTTPStub.makeSession([reply])
            let provider = try provider(http: http)
            try provider.restoreConversationState(state(history, tokens: 9_500), history: history)
            do {
                _ = try await provider.compactIfNeeded(history, pending: [], model: model, instructions: "", tools: [])
                throw CheckFailure(description: "Invalid compaction succeeded")
            } catch is ExecError {} catch is OpenAIHTTPError {}
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

    func reportedCountsLegacyStateAndClosedToolBoundaries() async throws {
        let history = [Message(role: .user, text: "Question"), Message(role: .assistant, text: "old answer")]
        let measured = try CodexConversationState.restore(state(history, tokens: 8_000))
        let pending = Message(role: .user, text: String(repeating: "x", count: 6_000))
        try expect(measured.reportedTokens(history + [pending]) == nil)
        let legacy = try CodexConversationState.restore(JSONEncoder().encode(measured.outputs))
        try expect(legacy.prefix == nil && legacy.outputs == measured.outputs)
        let http = HTTPStub.makeSession([])
        defer { http.invalidateAndCancel() }
        let provider = try provider(http: http)
        let withoutMeasurement = try await provider.compactIfNeeded(history, pending: [pending], model: model, instructions: "", tools: [])
        try expect(!withoutMeasurement)
        try provider.restoreConversationState(state(history, tokens: 8_000), history: history)
        let belowThreshold = try await provider.compactIfNeeded(history, pending: [pending], model: model, instructions: "", tools: [])
        try expect(!belowThreshold && HTTPStub.state.requests.isEmpty)
        var unfinished = history
        unfinished[1].toolCalls = [ToolCall(id: "pending", name: "shell", arguments: "{}")]
        try provider.restoreConversationState(state(unfinished, tokens: 9_500), history: unfinished)
        do {
            _ = try await provider.compactIfNeeded(unfinished, pending: [], model: model, instructions: "", tools: [])
            throw CheckFailure(description: "Compacted an unanswered call")
        } catch let error as ExecError { try expect(error.message.contains("unresolved")) }
        do {
            _ = try await provider.compactIfNeeded(history, pending: [], model: ChatModel(id: "unknown", name: "Unknown"), instructions: "", tools: [])
            throw CheckFailure(description: "Ignored a missing model limit")
        } catch let error as ExecError { try expect(error.message.contains("context limit")) }
        try expect(HTTPStub.state.requests.isEmpty)
        http.invalidateAndCancel()
        let catalogHTTP = HTTPStub.makeSession([.init(chunks: [Data("{\"models\":[{\"slug\":\"test\",\"context_window\":20000,\"effective_context_window_percent\":80}]}".utf8)])])
        defer { catalogHTTP.invalidateAndCancel() }
        let catalogProvider = try self.provider(http: catalogHTTP)
        let catalog = try await catalogProvider.models()
        try expect(catalog.first?.contextWindow == 16_000)
    }

    func toolResultMeasurementsStayBoundToCompletedResponse() async throws {
        let calls = [ToolCall(id: "first", name: "list_files", arguments: #"{"path":"."}"#),
                     ToolCall(id: "second", name: "list_files", arguments: #"{"path":"."}"#)]
        let history = [Message(role: .user, text: "Inspect"),
                       Message(role: .assistant, text: "", toolCalls: calls)]
        let results = calls.map { Message(role: .tool, text: "file.swift", toolResult: ToolResult(call: $0, text: "file.swift")) }
        let measured = CodexConversationState(measurement: .init(inputID: history[0].id, tokens: 9_500))
        let resolved = history + results
        try expect(measured.reportedTokens(resolved) == 9_500)
        try expect(measured.reportedTokens(resolved + [Message(role: .user, text: "Next")]) == nil)
        try expect(measured.reportedTokens(resolved + [Message(role: .assistant, text: "Unmeasured reply")]) == nil)
        try expect(measured.reportedTokens(Array(resolved.dropFirst())) == nil)
        for status in [Message.Status.interrupted, .failed, .streaming] {
            var incomplete = resolved
            incomplete[1].status = status
            try expect(measured.reportedTokens(incomplete) == nil)
        }
        var incompleteResult = resolved
        incompleteResult[2].status = .interrupted
        try expect(measured.reportedTokens(incompleteResult) == nil)
        let unrelated = ToolCall(id: "other", name: "list_files", arguments: "{}")
        try expect(measured.reportedTokens(history + [Message(role: .tool, text: "", toolResult: ToolResult(call: unrelated, text: ""))]) == nil)

        // A partially answered batch still must not reach the compaction endpoint.
        let http = HTTPStub.makeSession([])
        defer { http.invalidateAndCancel() }
        let provider = try provider(http: http)
        let partial = history + [results[0]]
        try provider.restoreConversationState(JSONEncoder().encode(measured), history: partial)
        do {
            _ = try await provider.compactIfNeeded(partial, pending: [], model: model, instructions: "", tools: [])
            throw CheckFailure(description: "Compacted a partially answered tool batch")
        } catch let error as ExecError { try expect(error.message.contains("unresolved")) }
        try expect(HTTPStub.state.requests.isEmpty)
    }

    func compactsDuringMultiRoundToolTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("file.swift"))
        func call(_ id: String) -> [[String: Any]] {
            [["type": "function_call", "call_id": id, "name": "list_files", "arguments": #"{"path":"."}"#]]
        }
        let http = HTTPStub.makeSession([
            .init(chunks: [try stream(call("first"), tokens: 9_499)]),
            .init(chunks: [try stream(call("second"), tokens: 9_500)]),
            .init(chunks: [try stream(compacted)]),
            .init(chunks: [try stream([["type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": "Done"]]]], tokens: 200)])
        ])
        defer { http.invalidateAndCancel() }
        let provider = try provider(http: http)
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let store = ChatStore(provider: provider, sessions: sessions, newConversation: true, workspace: try Workspace.load(root))
        store.models = [model]
        store.selectedModel = model.id
        var checkpointedBeforeContinuation = false
        var checkpointedActivity = false
        store.didCheckpoint = {
            let activities = store.messages.filter { $0.compaction != nil }
            if activities.last?.status == .streaming {
                try expect(activities.count == 1 && activities[0].compaction == .automatic)
                try expect(HTTPStub.state.requests.count == 2)
                try expect(store.contextUsage?.percent == 95)
                let saved = try await sessions.load(id: store.currentSessionID)!
                try expect(saved.messages.contains { $0.id == activities[0].id })
                try expect(saved.history.allSatisfy { $0.compaction == nil })
                checkpointedActivity = true
            }
            guard !checkpointedBeforeContinuation,
                  let saved = try await sessions.load(id: store.currentSessionID),
                  let prefix = try CodexConversationState.restore(saved.providerState).prefix else { return }
            try expect(HTTPStub.state.requests.count == 3)
            try expect(saved.history.last?.id == prefix.throughID)
            try expect(saved.history.last?.toolResult?.call.id == "second")
            try expect(activities.last?.status == .complete)
            try expect(store.contextUsage == nil) // Footer falls back to 0%, never stale 95%.
            checkpointedBeforeContinuation = true
        }
        store.draft = "Inspect the workspace twice"
        store.send()
        await store.waitUntilIdle()
        try expect(store.error == nil && store.messages.last?.text == "Done")
        try expect(checkpointedBeforeContinuation && checkpointedActivity)
        try expect(store.contextUsage?.percent == 2)
        try expect(store.messages[store.messages.count - 2].compaction == .automatic)
        try expect(store.messages.compactMap { $0.toolResult?.call.id } == ["first", "second"])
        let requests = HTTPStub.state.requests
        try expect(requests.count == 4)
        let inputs = try requests.map { request -> [[String: Any]] in
            let body = try JSONSerialization.jsonObject(with: HTTPStub.body(of: request)) as! [String: Any]
            return body["input"] as! [[String: Any]]
        }
        // Below threshold, the first tool result goes straight into normal inference.
        try expect(inputs[1].last?["call_id"] as? String == "first")
        // At threshold, both results are compacted before continuing the same turn.
        try expect(inputs[2].last?["type"] as? String == "compaction_trigger")
        let results = inputs[2].filter { $0["type"] as? String == "function_call_output" }
        try expect(results.compactMap { $0["call_id"] as? String } == ["first", "second"])
        try expect(results.allSatisfy { ($0["output"] as? String)?.contains("file.swift") == true })
        try expect(inputs[3].count == 1 && inputs[3][0]["type"] as? String == "compaction")
        let saved = try await sessions.load(id: store.currentSessionID)!
        let restored = try CodexConversationState.restore(saved.providerState)
        try expect(saved.messages == store.messages)
        try expect(saved.history == store.messages.filter { $0.compaction == nil })
        try expect(restored.requestUsage?.map(\.kind) == [.main, .main, .compaction, .main])
        // Replaying the saved conversation keeps the compacted prefix and final answer.
        let replay = try restored.input(saved.history)
        try expect(replay.count == 2 && replay[0]["type"] as? String == "compaction")
        try expect(replay[1]["type"] as? String == "message")
    }

    func manualCompactionBypassesThresholdAndPreservesTranscript() async throws {
        let response = try stream(compacted)
        let http = HTTPStub.makeSession([.init(chunks: [response])])
        defer { http.invalidateAndCancel() }
        let provider = try provider(http: http)
        let history = [Message(role: .user, text: "Question"), Message(role: .assistant, text: "Answer")]
        try provider.restoreConversationState(state(history, tokens: 100), history: history)
        let tools = [ToolDefinition(name: "list_files", description: "List files", parameters: [])]
        try await provider.compact(history, model: model, instructions: "Keep instructions", tools: tools)
        try expect(provider.contextUsage(history, model: model, instructions: "", tools: []) == nil)
        try expect(HTTPStub.state.requests.count == 1)
        let body = try JSONSerialization.jsonObject(with: HTTPStub.body(of: HTTPStub.state.requests[0])) as! [String: Any]
        try expect((body["tools"] as? [[String: Any]])?.first?["name"] as? String == "list_files")
        try expect(try CodexConversationState.restore(provider.encodeConversationState()).prefix?.throughID == history.last?.id)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let fake = FakeProvider()
        let store = ChatStore(provider: fake, sessions: sessions)
        store.restore(); await store.waitUntilIdle()
        try expect(!store.canCompact)
        store.draft = "First"; store.send(); await store.waitUntilIdle()
        let transcript = store.messages
        store.draft = "Keep my draft"
        var requests = 0
        fake.manualCompactionAction = { history in
            requests += 1
            try expect(history == transcript)
            try expect(store.messages.last?.compaction == .manual && store.messages.last?.status == .streaming)
            let saved = try await sessions.load(id: store.currentSessionID)!
            try expect(saved.messages == store.messages && saved.history == transcript)
            var recovered = saved
            try expect(recovered.recoverInterruptedTurn())
            try expect(recovered.messages.last?.compaction == .manual && recovered.messages.last?.status == .interrupted)
            try expect(recovered.history == transcript)
            try await Task.sleep(for: .milliseconds(20))
        }
        store.compact()
        try expect(store.busy && !store.canCompact && !store.isSending)
        store.compact() // Repeated activation cannot issue a second request.
        await store.waitUntilIdle()
        try expect(requests == 1 && Array(store.messages.dropLast()) == transcript && store.draft == "Keep my draft")
        try expect(store.messages.last?.compaction == .manual && store.messages.last?.status == .complete)
        try expect(fake.inputs.count == 1 && store.error == nil)
        let saved = try await sessions.load(id: store.currentSessionID)
        try expect(saved?.messages == store.messages && saved?.history == transcript)
        fake.manualCompactionAction = { _ in
            requests += 1
            try await Task.sleep(for: .seconds(60))
        }
        store.compact()
        for _ in 0..<100 {
            if requests == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        store.stop(); await store.waitUntilIdle()
        try expect(requests == 2 && store.messages.filter { $0.compaction == nil } == transcript && store.error == nil && !store.busy)
        try expect(store.messages.last?.compaction == .manual && store.messages.last?.status == .interrupted)
        fake.manualCompactionAction = { _ in throw ExecError("Compaction unavailable") }
        store.compact(); await store.waitUntilIdle()
        try expect(store.messages.last?.compaction == .manual && store.messages.last?.status == .failed)
        try expect(store.error == "Compaction unavailable")
        store.draft = "Continue"; store.send(); await store.waitUntilIdle()
        try expect(fake.inputs.count == 2 && fake.inputs.last?.contains { $0.compaction != nil } == false)
        let finished = try await sessions.load(id: store.currentSessionID)!
        try expect(finished.messages.filter { $0.compaction != nil }.map(\.status) == [.complete, .interrupted, .failed])
        try expect(finished.history.allSatisfy { $0.compaction == nil })
    }

    func automaticCompactionFailuresPreserveInput() async throws {
        for cancel in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let answer: [[String: Any]] = [["type": "message", "role": "assistant",
                "content": [["type": "output_text", "text": "Answer"]]]]
            let http = HTTPStub.makeSession([
                .init(chunks: [try stream(answer, tokens: 9_500)]),
                cancel ? .init(holdOpen: true) : .init(chunks: [try stream([])])
            ])
            defer { http.invalidateAndCancel() }
            let provider = try provider(http: http)
            let sessions = SessionStore(directory: root)
            let store = ChatStore(provider: provider, sessions: sessions, newConversation: true)
            store.models = [model]; store.selectedModel = model.id
            store.draft = "First"; store.send(); await store.waitUntilIdle()
            try expect(store.contextUsage?.percent == 95)
            try expect(store.messages.allSatisfy { $0.compaction == nil })
            store.draft = "Keep this question"; store.send()
            if cancel {
                for _ in 0..<400 {
                    if HTTPStub.state.heldCount == 1 { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                try expect(HTTPStub.state.heldCount == 1)
                let activity = store.messages.first { $0.compaction == .automatic }
                try expect(activity?.status == .streaming)
                store.stop()
            }
            await store.waitUntilIdle()
            let activities = store.messages.filter { $0.compaction != nil }
            try expect(activities.count == 1 && activities[0].status == (cancel ? .interrupted : .failed))
            try expect(store.contextUsage?.percent == 95)
            try expect(store.pendingInput.map(\.text) == ["Keep this question"])
            try expect(HTTPStub.state.requests.count == 2) // No inference or retry after the failure.
            let saved = try await sessions.load(id: store.currentSessionID)!
            try expect(saved.messages == store.messages)
            try expect(saved.history.allSatisfy { $0.compaction == nil })
            try expect(try CodexConversationState.restore(saved.providerState).prefix == nil)
        }
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
        provider.compactionAction = { true }
        provider.compactionCompletionAction = {
            try FileManager.default.removeItem(at: directory)
            try Data("not a directory".utf8).write(to: directory)
        }
        store.draft = "Continue"
        store.send()
        await store.waitUntilIdle()
        try expect(provider.inputs.isEmpty && store.hasUnsavedChanges)
        try expect(store.error?.contains("Could not save") == true)
    }
}
