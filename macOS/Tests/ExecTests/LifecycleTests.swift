import Foundation

@MainActor struct LifecycleTests {
    private func credentials(expired: Bool = false) throws -> MemoryCredentials {
        let store = MemoryCredentials()
        store.data = try JSONEncoder().encode(OpenAIAuthentication.Session(
            subject: "test-user", email: "test@example.com", accountID: "workspace",
            access: "old-access", refresh: "old-refresh", expires: Date().addingTimeInterval(expired ? -60 : 3600)
        ))
        return store
    }

    private func refreshedToken() throws -> Data {
        let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"workspace"}}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: [
            "access_token": "header.\(payload).signature", "refresh_token": "new-refresh",
            "expires_in": 3600, "token_type": "Bearer"
        ])
    }

    func refreshIsSharedAndSurvivesRestart() async throws {
        let store = try credentials(expired: true)
        let http = HTTPStub.makeSession([.init(chunks: [try refreshedToken()]), .init()])
        defer { http.invalidateAndCancel() }
        let auth = try OpenAIAuthentication(keychain: store, http: http)
        try expect(auth.account == "test@example.com")
        let first = Task { try await auth.credentials() }
        let second = Task { try await auth.credentials() }
        let a = try await first.value
        let b = try await second.value
        try expect(a.refresh == "new-refresh" && a.access == b.access)
        try expect(HTTPStub.state.requests.count == 1)
        let restarted = try OpenAIAuthentication(keychain: store, http: http)
        let restored = try await restarted.credentials()
        try expect(restored.access == a.access)
        try expect(HTTPStub.state.requests.count == 1)
        try await restarted.disconnect()
        try expect(restarted.account == nil && store.data == nil)
        let revoke = HTTPStub.state.requests.last!
        try expect(revoke.url?.path == "/api/accounts/oauth/revoke")
        try expect(String(decoding: HTTPStub.body(of: revoke), as: UTF8.self).contains("token=new-refresh"))
    }

    func cancellingOneCallerDoesNotCancelSharedRefresh() async throws {
        let store = try credentials(expired: true)
        let http = HTTPStub.makeSession([.init(chunks: [try refreshedToken()], holdOpen: true)])
        defer { http.invalidateAndCancel() }
        let auth = try OpenAIAuthentication(keychain: store, http: http)
        let first = Task { try await auth.credentials() }
        let second = Task { try await auth.credentials() }
        try await waitUntil { HTTPStub.state.heldCount == 1 }
        first.cancel()
        try await Task.sleep(for: .milliseconds(20))
        try expect(HTTPStub.state.stoppedURLs.isEmpty)
        HTTPStub.state.finishHeld()
        do { _ = try await first.value; throw CheckFailure(description: "Cancelled caller succeeded") }
        catch is CancellationError {}
        let result = try await second.value
        try expect(result.refresh == "new-refresh" && HTTPStub.state.requests.count == 1)
        let restarted = try OpenAIAuthentication(keychain: store, http: http)
        let saved = try await restarted.credentials()
        try expect(saved.refresh == "new-refresh" && HTTPStub.state.requests.count == 1)
    }

    func interruptedRefreshIsNotReplayedAfterRestart() async throws {
        let store = try credentials(expired: true)
        let http = HTTPStub.makeSession([.init(holdOpen: true)])
        defer { http.invalidateAndCancel() }
        let auth = try OpenAIAuthentication(keychain: store, http: http)
        let refresh = Task { try await auth.credentials() }
        try await waitUntil { !HTTPStub.state.requests.isEmpty }
        refresh.cancel()
        http.invalidateAndCancel() // Simulate a lost transport/process, not just one cancelled waiter.
        do {
            _ = try await refresh.value
            throw CheckFailure(description: "Cancelled refresh succeeded")
        } catch is CancellationError {} catch let error as URLError {
            try expect(error.code == .cancelled)
        }
        let restarted = try OpenAIAuthentication(keychain: store, http: http)
        do {
            _ = try await restarted.credentials()
            throw CheckFailure(description: "Uncertain refresh token was reused")
        } catch let error as ExecError { try expect(error.message.contains("Reconnect")) }
        try expect(HTTPStub.state.requests.count == 1)
    }

    func rotatedTokensSurviveTemporaryKeychainFailure() async throws {
        let store = try credentials(expired: true)
        store.failWrite = 2 // Save refresh-in-progress, then fail saving rotated tokens.
        let http = HTTPStub.makeSession([.init(chunks: [try refreshedToken()])])
        defer { http.invalidateAndCancel() }
        let auth = try OpenAIAuthentication(keychain: store, http: http)
        do {
            _ = try await auth.credentials()
            throw CheckFailure(description: "Expected persistence error")
        } catch let error as ExecError { try expect(error.message.contains("Keychain")) }
        let recovered = try await auth.credentials()
        try expect(recovered.refresh == "new-refresh")
        try expect(HTTPStub.state.requests.count == 1)
        let restarted = try OpenAIAuthentication(keychain: store, http: http)
        let saved = try await restarted.credentials()
        try expect(saved.access == recovered.access)
    }

    func signOutClearsLocalSessionWhenOffline() async throws {
        let store = try credentials()
        let http = HTTPStub.makeSession([.init(error: URLError(.notConnectedToInternet))])
        defer { http.invalidateAndCancel() }
        let auth = try OpenAIAuthentication(keychain: store, http: http)
        do {
            try await auth.disconnect()
            throw CheckFailure(description: "Expected unconfirmed revocation warning")
        } catch let error as ExecError { try expect(error.message.contains("not confirmed")) }
        try expect(auth.account == nil && store.data == nil)
        try expect(HTTPStub.state.requests.count == 1)
        let restarted = try OpenAIAuthentication(keychain: store, http: http)
        try expect(restarted.account == nil)
    }

    func providerPreservesOpaqueFollowupContext() async throws {
        let terminal = Data(#"data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","encrypted_content":"opaque"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}]}}"#.utf8) + Data("\n\n".utf8)
        let http = HTTPStub.makeSession(Array(repeating: .init(chunks: [terminal]), count: 3))
        defer { http.invalidateAndCancel() }
        let auth = try OpenAIAuthentication(keychain: credentials(), http: http)
        let provider = try OpenAIProvider(authentication: auth, http: http)
        let user = Message(role: .user, text: "First")
        for try await _ in provider.send([user], model: "test", instructions: "Project-specific rules") {}
        for try await _ in provider.send([user, Message(role: .assistant, text: "Hello"), Message(role: .user, text: "Second")], model: "test") {}
        for try await _ in provider.send([Message(role: .user, text: "New")], model: "test") {}
        let requests = HTTPStub.state.requests
        try expect(requests.count == 3)
        let first = try JSONSerialization.jsonObject(with: HTTPStub.body(of: requests[0])) as! [String: Any]
        try expect((first["instructions"] as? String)?.contains("Project-specific rules") == true)
        let followup = try JSONSerialization.jsonObject(with: HTTPStub.body(of: requests[1])) as! [String: Any]
        let input = followup["input"] as! [[String: Any]]
        try expect(input.count == 4 && input[1]["encrypted_content"] as? String == "opaque")
        let fresh = try JSONSerialization.jsonObject(with: HTTPStub.body(of: requests[2])) as! [String: Any]
        try expect((fresh["input"] as? [[String: Any]])?.count == 1)
        try expect((fresh["instructions"] as? String)?.contains("Project-specific rules") == false)
    }

    func providerEncodesToolsAndPreservesToolRoundTrips() async throws {
        func terminal(_ output: [[String: Any]]) throws -> Data {
            let event: [String: Any] = ["type": "response.completed", "response": ["status": "completed", "output": output]]
            return Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: event)) + Data("\n\n".utf8)
        }
        let call = ToolCall(id: "call-1", name: "list_files", arguments: #"{"path":"."}"#)
        let output: [[String: Any]] = [
            ["type": "reasoning", "encrypted_content": "opaque-reasoning"],
            ["type": "function_call", "call_id": call.id, "name": call.name, "arguments": call.arguments]
        ]
        let itemEvents = try output.enumerated().reduce(into: Data()) { data, entry in
            let event: [String: Any] = ["type": "response.output_item.done", "output_index": entry.offset, "item": entry.element]
            data += Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: event)) + Data("\n\n".utf8)
        }
        let finalText = "Project contains file.swift."
        let finalMessage: [[String: Any]] = [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": finalText]]]]
        // Reproduce Codex item completions followed by an empty terminal output,
        // then a text answer present only in the final response (no deltas).
        let http = HTTPStub.makeSession([
            .init(chunks: [itemEvents, try terminal([])]),
            .init(chunks: [try terminal(finalMessage)])
        ])
        defer { http.invalidateAndCancel() }
        let auth = try OpenAIAuthentication(keychain: credentials(), http: http)
        let provider = try OpenAIProvider(authentication: auth, http: http)
        let user = Message(role: .user, text: "Inspect project")
        var received: [ToolCall] = []
        for try await event in provider.send([user], model: "test", tools: CodingTools.definitions) {
            if case .toolCall(let call) = event { received.append(call) }
        }
        try expect(received == [call])
        let assistant = Message(role: .assistant, text: "", toolCalls: received)
        let result = Message(role: .tool, text: "file.swift", toolResult: ToolResult(call: call, text: "file.swift"))
        let savedState = try provider.encodeConversationState()
        let resumed = try provider.makeConversationProvider()
        let emptyState = try resumed.encodeConversationState()!
        try expect(try CodexConversationState.restore(emptyState).outputs.isEmpty)
        try expect(resumed.conversationIdentity == provider.conversationIdentity)
        try resumed.restoreConversationState(savedState, history: [user, assistant, result])
        resumed.clearConversationState()
        try expect(!(try CodexConversationState.restore(provider.encodeConversationState())).outputs.isEmpty)
        try resumed.restoreConversationState(savedState, history: [user, assistant, result])
        let savedMessages = try JSONEncoder().encode([user, assistant, result])
        let restoredMessages = try JSONDecoder().decode([Message].self, from: savedMessages)
        try expect(restoredMessages.first?.id == user.id)
        var snapshots: [String] = []
        for try await event in resumed.send(restoredMessages, model: "test", effort: nil, instructions: "", tools: CodingTools.definitions) {
            if case .textSnapshot(let text) = event { snapshots.append(text) }
        }
        try expect(snapshots == [finalText])
        let requests = HTTPStub.state.requests
        try expect(requests.count == 2)
        let first = try JSONSerialization.jsonObject(with: HTTPStub.body(of: requests[0])) as! [String: Any]
        try expect((first["tools"] as? [[String: Any]])?.count == 5)
        try expect(first["parallel_tool_calls"] as? Bool == false)
        let second = try JSONSerialization.jsonObject(with: HTTPStub.body(of: requests[1])) as! [String: Any]
        let input = second["input"] as! [[String: Any]]
        try expect(input.count == 4 && input[1]["encrypted_content"] as? String == "opaque-reasoning")
        try expect(input[2]["type"] as? String == "function_call")
        try expect(input[3]["type"] as? String == "function_call_output")
        try expect(input[3]["call_id"] as? String == call.id && input[3]["output"] as? String == "file.swift")
        try expectFailure {
            try resumed.restoreConversationState(JSONEncoder().encode([user.id: Data("corrupt".utf8)]), history: [user])
        }
    }

    func streamCancellationClosesRequestAndPrematureEOFIsFailure() async throws {
        let delta = Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}\n\n".utf8)
        // URLProtocol buffers small payloads with AsyncBytes. Fill its buffer
        // while keeping the response open so cancellation reaches a live request.
        let buffered = delta + Data((":" + String(repeating: " ", count: 65536) + "\n\n").utf8)
        let http = HTTPStub.makeSession([.init(chunks: [buffered], holdOpen: true), .init(chunks: [delta])])
        defer { http.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://test.invalid/stream")!)
        var received = false
        var finished = false
        let consumer = Task { @MainActor in
            defer { finished = true }
            for try await _ in OpenAITransport.stream(request, session: http) { received = true }
        }
        try await waitUntil("first stream event") { received }
        consumer.cancel()
        try await waitUntil("cancelled stream request") { finished && HTTPStub.state.stoppedURLs.contains(request.url!) }
        _ = await consumer.result
        do {
            for try await _ in OpenAITransport.stream(request, session: http) {}
            throw CheckFailure(description: "Premature EOF reported success")
        } catch let error as ExecError { try expect(error.message.contains("before completion")) }
        try expect(HTTPStub.state.requests.count == 2)
    }

    private func waitUntil(_ operation: String = "request start", _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out waiting for \(operation)")
    }
}
