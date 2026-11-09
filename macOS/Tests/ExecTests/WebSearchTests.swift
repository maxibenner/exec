import Foundation

@MainActor struct WebSearchTests {
    private let call = ToolCall(id: "search-1", name: "web_search", arguments: #"{"query":"Swift release notes"}"#)

    private func provider(_ http: URLSession) throws -> OpenAIProvider {
        let credentials = MemoryCredentials()
        credentials.data = try JSONEncoder().encode(OpenAIAuthentication.Session(
            subject: "test-user", email: "test@example.com", accountID: "workspace",
            access: "test-access", refresh: "test-refresh", expires: Date().addingTimeInterval(3600)
        ))
        return try OpenAIProvider(authentication: OpenAIAuthentication(keychain: credentials, http: http), http: http)
    }

    private func terminal(_ output: [[String: Any]]) throws -> Data {
        let event: [String: Any] = ["type": "response.completed", "response": ["status": "completed", "output": output,
            "model": "reported-model", "usage": ["input_tokens": 1000, "output_tokens": 100,
                "input_tokens_details": ["cached_tokens": 900], "output_tokens_details": ["reasoning_tokens": 40]]]]
        return Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: event)) + Data("\n\n".utf8)
    }

    private var callOutput: [[String: Any]] { [
        ["type": "reasoning", "encrypted_content": "main-context"],
        ["type": "function_call", "call_id": call.id, "name": call.name, "arguments": call.arguments]
    ] }

    private var searchOutput: [[String: Any]] { [
        ["type": "reasoning", "encrypted_content": "search-only-context"],
        ["type": "web_search_call", "status": "completed", "action": ["type": "search", "sources": [
            ["url": "https://swift.org/download/", "title": "Download Swift"],
            ["url": "https://swift.org/", "title": "Duplicate"]
        ]]],
        ["type": "message", "content": [["type": "output_text", "text": "Official Swift information.", "annotations": [
            ["type": "url_citation", "url": "https://swift.org/", "title": "Swift"],
            ["type": "url_citation", "url": "javascript:alert(1)", "title": "Unsafe"]
        ]]]]
    ] }

    private var answer: [[String: Any]] { [
        ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "See [Swift](https://swift.org/)."]]]
    ] }

    private func configure(_ store: ChatStore) {
        store.models = [ChatModel(id: "test", name: "Test", contextWindow: 100_000,
                                 efforts: [ChatEffort(id: "low", name: "Low")])]
        store.selectedModel = "test"
        store.selectedEffort = "low"
    }

    func roundTripKeepsSearchSeparateAndSavesSources(searchModel: String? = nil) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let http = HTTPStub.makeSession([
            .init(chunks: [try terminal(callOutput)]), .init(chunks: [try terminal(searchOutput)]),
            .init(chunks: [try terminal(answer)]), .init(chunks: [try terminal(answer)])
        ])
        defer { http.invalidateAndCancel() }
        let provider = try provider(http)
        let store = ChatStore(provider: provider, sessions: sessions, newConversation: true)
        configure(store)
        if let searchModel { store.searchModel = searchModel }
        store.draft = "Private conversation marker. Find Swift release notes."
        store.send()
        await store.waitUntilIdle()
        try expect(store.error == nil && HTTPStub.state.requests.count == 3 && store.workspace == nil)
        let requests = HTTPStub.state.requests
        let initial = try body(requests[0])
        try expect((initial["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["web_search", "generate_image", "fetch_content", "take_screenshot", "computer_use"])
        let search = try body(requests[1])
        try expect(requests[1].url?.absoluteString == CodexConnection.baseURL + "/responses")
        try expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer test-access")
        try expect(requests[1].value(forHTTPHeaderField: "ChatGPT-Account-ID") == "workspace")
        try expect(search["model"] as? String == (searchModel ?? "gpt-6-luna") && search["tool_choice"] as? String == "required")
        try expect(search["reasoning"] == nil)
        try expect(initial["model"] as? String == "test")
        try expect((initial["reasoning"] as? [String: String])?["effort"] == "low")
        try expect(search["store"] as? Bool == false && search["stream"] as? Bool == true)
        try expect(search["include"] as? [String] == ["web_search_call.action.sources"])
        try expect((search["tools"] as? [[String: String]]) == [["type": "web_search"]])
        try expect(search["prompt_cache_key"] as? String != initial["prompt_cache_key"] as? String)
        let searchInput = search["input"] as! [[String: Any]]
        try expect(searchInput.count == 1)
        let content = searchInput[0]["content"] as! [[String: String]]
        try expect(content == [["type": "input_text", "text": "Swift release notes"]])
        try expect(!String(decoding: HTTPStub.body(of: requests[1]), as: UTF8.self).contains("Private conversation marker"))
        let continued = String(decoding: HTTPStub.body(of: requests[2]), as: UTF8.self)
        try expect(continued.contains("main-context") && !continued.contains("search-only-context"))
        let persisted = try await sessions.load(id: store.currentSessionID)!
        let usage = try CodexConversationState.restore(persisted.providerState).requestUsage ?? []
        try expect(usage.map(\.kind) == [.main, .search, .main])
        try expect(usage.map(\.requestedModel) == ["test", searchModel ?? "gpt-6-luna", "test"])
        try expect(usage.map(\.requestedEffort) == ["low", nil, "low"])
        try expect(usage.allSatisfy { $0.outcome == .completed && $0.usage?.model == "reported-model"
            && $0.usage?.cachedInputTokens == 900 && $0.usage?.reasoningTokens == 40
            && $0.usage?.contextTokens == 1100 })
        try expect(!continued.contains("cachedInputTokens") && !continued.contains("reported-model"))
        let result = persisted.messages.compactMap(\.toolResult).first!
        try expect(result.webSearch?.sources.map(\.url) == ["https://swift.org/", "https://swift.org/download/"])
        try expect(result.text.contains("Official Swift information.") && result.text.contains("https://swift.org/"))
        try expect(persisted.history.contains { $0.toolResult?.webSearch == result.webSearch })
        let resumed = try provider.makeConversationProvider()
        try resumed.restoreConversationState(persisted.providerState, history: persisted.history)
        for try await _ in resumed.send(persisted.history + [Message(role: .user, text: "Continue")],
                                        model: "test", effort: nil, instructions: "", tools: []) {}
        try expect(try CodexConversationState.restore(resumed.encodeConversationState()).requestUsage?.count == 4)
        let followup = String(decoding: HTTPStub.body(of: HTTPStub.state.requests.last!), as: UTF8.self)
        try expect(followup.contains("Official Swift information.") && !followup.contains("search-only-context"))
        // Old tool results still decode without search metadata.
        let old = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(ToolResult(call: call, text: "Old result")))
        try expect(old.webSearch == nil)
    }

    func searchModelPreferencePersistsAcrossConversations() async throws {
        let suite = "ExecSearchModelTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let sessions = SessionStore(directory: root)
        let library = try ChatLibrary(provider: FakeProvider(), sessions: sessions, preferences: preferences)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        try expect(library.searchModel == "gpt-6-luna" && library.current.searchModel == "gpt-6-luna")
        library.draft = "First conversation"
        library.send()
        try await wait { !library.hasRunningOperations }
        let first = library.current
        let firstID = library.currentSessionID!

        library.searchModel = "custom-search"
        try expect(first.searchModel == "custom-search" && first.selectedModel == "test")
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        try expect(library.current.searchModel == "custom-search")
        library.searchModel = "another-search"
        try expect(first.searchModel == "another-search" && library.current.searchModel == "another-search")
        library.openSession(firstID)
        try await wait { !library.hasRunningOperations }
        try expect(library.current === first && library.current.searchModel == "another-search")

        // Restoring old saved sessions must use the global choice, even if it is
        // temporarily absent from the model catalog, rather than the chat model.
        let restarted = try ChatLibrary(provider: FakeProvider(), sessions: sessions, preferences: preferences)
        defer { restarted.stopAll() }
        restarted.restore()
        try await wait { !restarted.hasRunningOperations }
        try expect(restarted.searchModel == "another-search")
        try expect(restarted.currentSessionID == firstID && restarted.current.searchModel == "another-search")
        try expect(restarted.selectedModel == "test")
    }

    func failuresContinueWithoutRetriesOrFalseSuccess() async throws {
        let failures: [HTTPStub.Reply] = [
            .init(status: 403),
            .init(chunks: [try terminal(answer)]), // A fluent answer without a search is not a search result.
            .init(chunks: [Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Partial\"}\n\n".utf8)]),
            .init(chunks: [try terminal([["type": "web_search_call", "status": "failed"]])])
        ]
        for failure in failures {
            let http = HTTPStub.makeSession([.init(chunks: [try terminal(callOutput)]), failure,
                .init(chunks: [try terminal(answer)])])
            let provider = try provider(http)
            let store = ChatStore(provider: provider, newConversation: true)
            configure(store)
            store.draft = "Search"
            store.send()
            await store.waitUntilIdle()
            try expect(store.error == nil && HTTPStub.state.requests.count == 3)
            let records = try CodexConversationState.restore(provider.encodeConversationState()).requestUsage ?? []
            try expect(records.map(\.kind) == [.main, .search, .main])
            try expect(records[1].requestedModel == "gpt-6-luna")
            if failure.status == 403 { try expect(records[1].outcome == .failed && records[1].usage == nil) }
            let result = store.messages.compactMap(\.toolResult).last!
            try expect(result.webSearch == nil && result.text.hasPrefix("Tool error:"))
            try expect(result.text.contains("Do not retry without a new user request."))
            let followup = String(decoding: HTTPStub.body(of: HTTPStub.state.requests[2]), as: UTF8.self)
            try expect(followup.contains("Tool error:") && followup.contains("function_call_output"))
            try expect(store.messages.last?.role == .assistant)
            http.invalidateAndCancel()
        }
    }

    func cancellationAndRestartDoNotResumeSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let http = HTTPStub.makeSession([.init(chunks: [try terminal(callOutput)]), .init(holdOpen: true)])
        defer { http.invalidateAndCancel() }
        let store = ChatStore(provider: try provider(http), sessions: sessions, newConversation: true)
        configure(store)
        store.draft = "Search"
        store.send()
        try await wait { HTTPStub.state.heldCount == 1 }
        var checkpoint = try await sessions.load(id: store.currentSessionID)!
        try expect(checkpoint.activeCallID == call.id)
        try expect(checkpoint.recoverInterruptedTurn())
        try expect(checkpoint.history.last?.text == WebSearchTool.interrupted)
        store.stop()
        await store.waitUntilIdle()
        try await wait { HTTPStub.state.heldCount == 0 }
        try expect(HTTPStub.state.requests.count == 2 && store.error == nil)
        let saved = try await sessions.load(id: store.currentSessionID)!
        try expect(!saved.activeTurn && saved.activeCallID == nil)
        let recorded = try CodexConversationState.restore(saved.providerState).requestUsage ?? []
        try expect(recorded.map(\.kind) == [.main, .search])
        try expect(recorded.last?.usage == nil && recorded.last?.outcome != .completed)
        try expect(saved.history.last?.text == WebSearchTool.interrupted && saved.history.last?.toolResult?.webSearch == nil)
        let restarted = ChatStore(provider: try provider(http), sessions: sessions, newConversation: true)
        configure(restarted)
        restarted.openSession(store.currentSessionID!, loadModels: false)
        await restarted.waitUntilIdle()
        try expect(restarted.messages.last?.text == WebSearchTool.interrupted && HTTPStub.state.requests.count == 2)
    }

    func parsingBoundsAndSourceSafety() throws {
        var output = searchOutput
        output.append(["type": "message", "content": [["type": "output_text", "text": String(repeating: "界", count: 6_000)]]])
        output.append(["type": "web_search_call", "status": "completed", "action": ["sources": (0..<30).map {
            ["title": String(repeating: "界", count: 300), "url": "https://example.com/\($0)"]
        }]])
        let result = try CodexWebSearch.result(JSONSerialization.data(withJSONObject: output), query: "valid")
        try expect(result.sources.count == 10 && result.answer.contains("truncated") && result.context.utf8.count <= 32_768)
        for url in ["file:///etc/passwd", "javascript:alert(1)", "https://user:secret@example.com", "/relative", "https://example.com/\nspoof"] {
            try expect(WebSearchResult.Source(title: "Unsafe", url: url).link == nil)
        }
        try expectFailure { _ = try CodexWebSearch.result(JSONSerialization.data(withJSONObject: answer), query: "valid") }
        try expectFailure { _ = try CodexWebSearch.result(JSONSerialization.data(withJSONObject: [["type": "web_search_call", "status": "completed"]]), query: "valid") }
        try expectFailure { _ = try WebSearchTool.validatedQuery("  ") }
        try expectFailure { _ = try WebSearchTool.validatedQuery("a\nb") }
        try expectFailure { _ = try WebSearchTool.validatedQuery(String(repeating: "a", count: 2_049)) }
        // Output items emitted separately from the terminal event remain available to the search parser.
        var decoder = OpenAITransport.ResponseDecoder()
        for (index, item) in searchOutput.enumerated() {
            _ = try decoder.decode(JSONSerialization.data(withJSONObject: ["type": "response.output_item.done", "output_index": index, "item": item]))
        }
        let done = try decoder.decode(Data(#"{"type":"response.completed","response":{"status":"completed","output":[]}}"#.utf8))
        guard case .completed(let data, _) = done else { throw CheckFailure(description: "Missing terminal output") }
        try expect(try CodexWebSearch.result(data, query: "valid").sources.count == 2)
    }

    func invalidInputAndCheckpointFailureMakeNoRequests() async throws {
        let http = HTTPStub.makeSession([])
        defer { http.invalidateAndCancel() }
        let provider = try provider(http)
        do {
            _ = try await provider.searchWeb(query: "", model: "test", effort: nil)
            throw CheckFailure(description: "Empty query accepted")
        } catch is ExecError {}
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.searchWeb(query: "Swift", model: "test", effort: nil)
        }
        do { _ = try await cancelled.value; throw CheckFailure(description: "Cancelled search accepted") }
        catch is CancellationError {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(provider: provider, sessions: SessionStore(directory: root), newConversation: true)
        configure(store)
        store.draft = "Search"
        store.send()
        await store.waitUntilIdle()
        try expect(store.error != nil && HTTPStub.state.requests.isEmpty)
        try expect(!FakeProvider().supportsWebSearch)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: HTTPStub.body(of: request)) as! [String: Any]
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Search operation did not settle")
    }
}
