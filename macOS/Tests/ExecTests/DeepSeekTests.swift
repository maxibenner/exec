import Foundation

@MainActor struct DeepSeekTests {
    private var catalog: Data { Data(#"{"data":[{"id":"deepseek-flash","name":"DeepSeek Flash","context_window":1048576,"input_modalities":["text","image"],"effort":{"supported_levels":["low","high","max"],"default_level":"high"}},{"id":"deepseek-v4-pro","input_modalities":["text"]}]}"#.utf8) }
    private func chunk(_ delta: [String: Any], finish: String? = nil) throws -> Data {
        let choice: [String: Any] = ["index": 0, "delta": delta, "finish_reason": finish as Any? ?? NSNull()]
        return Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: ["choices": [choice]])) + Data("\n\n".utf8)
    }
    private func answer(_ text: String = "Finished") throws -> Data {
        try chunk(["reasoning_content": "private-reasoning"]) + chunk(["content": text], finish: "stop") +
            Data("data: {\"choices\":[],\"usage\":{\"total_tokens\":240}}\n\ndata: [DONE]\n\n".utf8)
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: HTTPStub.body(of: request)) as! [String: Any]
    }
    private func connected(_ http: URLSession, credentials: MemoryCredentials = MemoryCredentials()) async throws -> DeepSeekProvider {
        let authentication = try DeepSeekAuthentication(store: credentials)
        try await authentication.connect(key: "test-deepseek-key", http: http)
        return DeepSeekProvider(authentication: authentication, http: http)
    }

    func authenticationIsTransactionalAndIndependent() async throws {
        let credentials = MemoryCredentials()
        let http = HTTPStub.makeSession([.init(chunks: [catalog]), .init(status: 401, chunks: [Data("test-SECRET".utf8)]), .init(chunks: [catalog])])
        defer { http.invalidateAndCancel() }
        let authentication = try DeepSeekAuthentication(store: credentials)
        try await authentication.connect(key: "test-deepseek-key", http: http)
        let identity = authentication.identity
        try expect(authentication.catalog.first?.efforts.map(\.id) == ["none", "low", "high", "max"])
        try expect(authentication.catalog.first?.acceptsImages == true)
        do { try await authentication.connect(key: "test-SECRET", http: http); throw CheckFailure(description: "Expected rejection") }
        catch let error as ExecError { try expect(!error.message.contains("test-SECRET")) }
        try expect(authentication.identity == identity && credentials.writes == 1)
        credentials.failWrite = 2
        do { try await authentication.connect(key: "replacement-key", http: http); throw CheckFailure(description: "Expected Keychain failure") }
        catch is ExecError {}
        try expect(try authentication.key() == "test-deepseek-key")
        let restored = try DeepSeekAuthentication(store: credentials, restoredData: credentials.data)
        try expect(restored.identity == identity && restored.account != nil)
        try restored.disconnect()
        try expect(credentials.data == nil && restored.account == nil)
        try expect(HTTPStub.state.requests.count == 3)
    }

    func toolRoundTripPersistsReasoningAndNativeSearch() async throws {
        let call = ["index": 0, "id": "search-1", "type": "function", "function": ["name": "web_search", "arguments": "{\"query\":"]] as [String: Any]
        let tail = ["index": 0, "function": ["arguments": "\"Swift\"}"]] as [String: Any]
        let response = try chunk(["reasoning_content": "search-reasoning"]) + chunk(["tool_calls": [call]]) +
            chunk(["tool_calls": [tail]], finish: "tool_calls") + Data("data: [DONE]\n\n".utf8)
        let search = Data(#"{"results":[{"title":"Swift","url":"https://swift.org/","snippet":"Swift","summary":"Official Swift information"},{"title":"Unsafe","url":"javascript:alert(1)","snippet":"x","summary":"x"}]}"#.utf8)
        let http = HTTPStub.makeSession([.init(chunks: [catalog]), .init(chunks: [response]), .init(chunks: [search]),
                                        .init(chunks: [try answer()]), .init(chunks: [try answer("Resumed")])])
        defer { http.invalidateAndCancel() }
        let provider = try await connected(http)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let store = ChatStore(provider: provider, sessions: sessions, newConversation: true)
        store.models = [ChatModel(id: "deepseek-flash", name: "Flash", contextWindow: 1048576, efforts: [.init(id: "high", name: "High")], acceptsImages: true)]
        store.selectedModel = "deepseek-flash"
        store.selectedEffort = "high"
        store.draft = "Private conversation marker. Search for Swift."
        store.send()
        await store.waitUntilIdle()
        try expect(store.error == nil)
        let requests = HTTPStub.state.requests
        try expect(requests.count == 4)
        try expect(requests.allSatisfy { $0.url?.host == "api.deepseek.com" })
        let initial = try body(requests[1])
        try expect(initial["model"] as? String == "deepseek-flash" && initial["reasoning_effort"] as? String == "high")
        let definitions = (initial["tools"] as! [[String: Any]]).map { $0["function"] as! [String: Any] }
        try expect(definitions.compactMap { $0["name"] as? String } == ["web_search", "fetch_content", "take_screenshot", "computer_use"])
        try expect(requests[2].url?.path == "/v1/tools/search")
        try expect(!String(decoding: HTTPStub.body(of: requests[2]), as: UTF8.self).contains("Private conversation marker"))
        let followup = try body(requests[3])["messages"] as! [[String: Any]]
        try expect(followup.contains { $0["reasoning_content"] as? String == "search-reasoning" })
        try expect(followup.contains { $0["role"] as? String == "tool" && $0["tool_call_id"] as? String == "search-1" })
        let snapshot = try await sessions.load(id: store.currentSessionID)!
        try expect(snapshot.messages.compactMap(\.toolResult).first?.webSearch?.sources.count == 1)
        try expect(store.contextUsage?.tokens == 240)
        let reopened = try provider.makeConversationProvider()
        try reopened.restoreConversationState(snapshot.providerState, history: snapshot.history)
        for try await _ in reopened.send(snapshot.history + [Message(role: .user, text: "Continue")], model: "deepseek-flash", effort: nil, instructions: "", tools: [WebSearchTool.definition]) {}
        let restored = try body(HTTPStub.state.requests.last!)["messages"] as! [[String: Any]]
        try expect(restored.filter { $0["role"] as? String == "assistant" }.compactMap { $0["reasoning_content"] as? String } == ["search-reasoning", "private-reasoning"])
    }

    func incompleteStreamsNeverCommitToolsOrReasoning() async throws {
        for finish in [String?.none, "length", "content_filter"] {
            let response = try chunk(["reasoning_content": "unfinished"]) + chunk(["tool_calls": [["index": 0, "id": "call", "type": "function", "function": ["name": "shell", "arguments": "{}"]]]], finish: finish)
            let http = HTTPStub.makeSession([.init(chunks: [catalog]), .init(chunks: [response])])
            let provider = try await connected(http)
            var calls = 0
            do {
                for try await event in provider.send([Message(role: .user, text: "Run")], model: "deepseek-flash", effort: nil, instructions: "", tools: CodingTools.definitions) {
                    if case .toolCall = event { calls += 1 }
                }
                throw CheckFailure(description: "Expected incomplete response failure")
            } catch is ExecError {}
            let context = try JSONDecoder().decode(DeepSeekConversationState.self, from: provider.encodeConversationState()!)
            try expect(context.reasoning.isEmpty && calls == 0 && HTTPStub.state.requests.count == 2)
            http.invalidateAndCancel()
        }
        var decoder = DeepSeekTransport.Decoder()
        do { _ = try decoder.decode(Data("[DONE]".utf8)); throw CheckFailure(description: "Expected missing finish failure") }
        catch is ExecError {}
    }

    func cancellationStopsTransportAndTextOnlyModelsRejectImages() async throws {
        let http = HTTPStub.makeSession([.init(chunks: [catalog]), .init(chunks: [try chunk(["content": "Partial", "reasoning_content": "unfinished"])], holdOpen: true)])
        defer { http.invalidateAndCancel() }
        let provider = try await connected(http)
        let store = ChatStore(provider: provider, newConversation: true)
        store.models = [ChatModel(id: "deepseek-flash", name: "Flash")]
        store.selectedModel = "deepseek-flash"
        store.draft = "Start"
        store.send()
        try await wait { HTTPStub.state.heldCount == 1 }
        store.stop()
        await store.waitUntilIdle()
        try await wait { !HTTPStub.state.stoppedURLs.isEmpty }
        try expect(store.messages.last?.status == .interrupted)
        let context = try JSONDecoder().decode(DeepSeekConversationState.self, from: provider.encodeConversationState()!)
        try expect(context.reasoning.isEmpty && HTTPStub.state.requests.count == 2)
        // Image validation must fail before another inference request, never omit the image.
        let image = ImageAttachment(name: "test.png", mediaType: "image/png", data: Data([1, 2, 3]))
        do {
            for try await _ in provider.send([Message(role: .user, text: "Look", images: [image])], model: "deepseek-v4-pro", effort: nil, instructions: "", tools: []) {}
            throw CheckFailure(description: "Expected image incompatibility")
        } catch let error as ExecError { try expect(error.message.contains("does not accept images")) }
        try expect(HTTPStub.state.requests.count == 2)
    }

    func balanceRequestAndValidation() async throws {
        let data = Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12.3456","granted_balance":"2","topped_up_balance":"10.3456"},{"currency":"CNY","total_balance":"0.00"}]}"#.utf8)
        let http = HTTPStub.makeSession([.init(chunks: [catalog]), .init(chunks: [data]),
                                        .init(status: 401, chunks: [Data("test-deepseek-key".utf8)])])
        defer { http.invalidateAndCancel() }
        let provider = try await connected(http)
        let registry = ProviderRegistry(entries: [.init(id: "deepseek", provider: provider)], libraryIdentity: "test")
        let multi = MultiProvider(registry: registry)
        try expect(multi.connections.first?.balanceIdentity == provider.conversationIdentity)
        let balances = try await multi.accountBalance(providerID: "deepseek")
        try expect(balances == [.init(amount: Decimal(string: "12.3456")!, currency: "USD"), .init(amount: 0, currency: "CNY")])
        let request = HTTPStub.state.requests[1]
        try expect(request.url?.absoluteString == "https://api.deepseek.com/user/balance" && request.httpMethod == "GET")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-deepseek-key")
        try expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == nil && request.httpBody == nil)
        do {
            _ = try await multi.accountBalance(providerID: "deepseek")
            throw CheckFailure(description: "Expected balance rejection")
        } catch let error as ExecError { try expect(!error.message.contains("test-deepseek-key")) }
        try expect(HTTPStub.state.requests.count == 3)
        for invalid in ["{}", #"{"balance_infos":[]}"#,
                        #"{"balance_infos":[{"currency":"USD","total_balance":"12oops"}]}"#,
                        #"{"balance_infos":[{"currency":"USD","total_balance":"NaN"}]}"#] {
            do { _ = try DeepSeekBalance.decode(Data(invalid.utf8)); throw CheckFailure(description: "Expected invalid balance") }
            catch is ExecError {}
        }
        try await provider.disconnect()
        let disconnected = try await multi.accountBalance(providerID: "deepseek")
        try expect(disconnected.isEmpty && HTTPStub.state.requests.count == 3)
    }

    func balanceDiscardsRemovedAccountResponse() async throws {
        let data = Data(#"{"balance_infos":[{"currency":"USD","total_balance":"10.00"}]}"#.utf8)
        let http = HTTPStub.makeSession([.init(chunks: [catalog]), .init(chunks: [data], holdOpen: true)])
        defer { http.invalidateAndCancel() }
        let provider = try await connected(http)
        let pending = Task { try await provider.accountBalance(providerID: "DeepSeek") }
        try await wait { HTTPStub.state.heldCount == 1 }
        try await provider.disconnect()
        HTTPStub.state.finishHeld()
        do { _ = try await pending.value; throw CheckFailure(description: "Expected stale balance cancellation") }
        catch is CancellationError {}
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "DeepSeek test timed out")
    }
}
