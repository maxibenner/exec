import Foundation

@MainActor struct EffortTests {
    func catalogAndRequestEncoding() async throws {
        let credentials = MemoryCredentials()
        credentials.data = try JSONEncoder().encode(OpenAIAuthentication.Session(
            subject: "test-user", email: "test@example.com", accountID: "workspace",
            access: "test-access", refresh: "test-refresh", expires: Date().addingTimeInterval(3600)
        ))
        let catalog = Data(#"{"models":[{"slug":"test","context_window":100000,"default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low","description":"Faster"},{"effort":"medium","description":"Balanced"},{"effort":"xhigh","description":"More reasoning"},{"effort":"low"}]},{"slug":"legacy","context_window":100000}]}"#.utf8)
        let done = Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Done\"}]}]}}\n\n".utf8)
        let http = HTTPStub.makeSession([.init(chunks: [catalog]), .init(chunks: [done])])
        defer { http.invalidateAndCancel() }
        let provider = try OpenAIProvider(authentication: OpenAIAuthentication(keychain: credentials, http: http), http: http)
        let models = try await provider.models()
        try expect(models[0].efforts.map(\.id) == ["low", "medium", "xhigh"])
        try expect(models[0].defaultEffort == "medium" && models[0].efforts.last?.name == "Extra High")
        try expect(models[1].efforts.isEmpty && models[1].defaultEffort == nil)
        for try await _ in provider.send([Message(role: .user, text: "Think")], model: "test", effort: "xhigh") {}
        let sent = try JSONSerialization.jsonObject(with: HTTPStub.body(of: HTTPStub.state.requests.last!)) as! [String: Any]
        try expect((sent["reasoning"] as? [String: String])?["effort"] == "xhigh")
        let defaultRequest = try CodexConnection.responsesRequest(input: [], model: "test", sessionID: "test",
                                                                 accessToken: "test", accountID: "test")
        let body = try JSONSerialization.jsonObject(with: defaultRequest.httpBody!) as! [String: Any]
        try expect(body["reasoning"] == nil)
    }

    func selectionPersistenceAndIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        provider.availableModels = [ChatModel(id: "test", name: "Test", efforts: [
            ChatEffort(id: "low", name: "Low"), ChatEffort(id: "high", name: "High")
        ], defaultEffort: "low"), ChatModel(id: "plain", name: "Plain")]
        let suite = "ExecEffortTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = try ChatLibrary(provider: provider, sessions: sessions, preferences: preferences)
        library.restore()
        try await wait { !library.hasRunningOperations }
        try expect(library.selectedEffort == nil)
        library.selectedEffort = "unsupported"
        try expect(library.selectedEffort == nil)
        library.selectedEffort = "high"
        library.draft = "First"
        let firstProvider = provider.children[0]
        firstProvider.holdOpen = true
        library.send()
        try await wait { firstProvider.pending != nil }
        let firstID = library.currentSessionID!
        library.selectedEffort = "low" // Controls cannot mutate an active turn.
        try expect(library.selectedEffort == "high" && firstProvider.efforts == ["high"])
        firstProvider.pending?.yield(.completed)
        firstProvider.pending?.finish()
        try await wait { !library.hasRunningOperations }
        let saved = try await sessions.load(id: firstID)
        try expect(saved?.effort == "high")

        library.defaultModel = "test"
        library.defaultEffort = "low"
        try expect(library.selectedEffort == "high") // Defaults never change the active session.
        library.newConversation()
        try await wait { !library.navigating }
        try expect(library.selectedModel == "test" && library.selectedEffort == "low")
        library.draft = "Second"
        library.send()
        try await wait { !library.hasRunningOperations }
        try expect(provider.children.last?.efforts == ["low"])
        library.openSession(firstID)
        try await wait { !library.navigating }
        try expect(library.selectedEffort == "high")

        // Selection is persisted independently of the immediate resident switch.
        try await wait { !library.hasRunningOperations }
        let restarted = try ChatLibrary(provider: provider, sessions: sessions, preferences: preferences)
        try expect(restarted.defaultModel == "test" && restarted.defaultEffort == "low")
        restarted.restore()
        try await wait { !restarted.hasRunningOperations }
        try expect(restarted.selectedEffort == "high")
        restarted.selectedModel = "plain"
        try expect(restarted.selectedEffort == nil && restarted.current.selectedEffort == nil)
        restarted.selectedModel = "test"
        restarted.selectedEffort = "high"
        restarted.current.models = [ChatModel(id: "test", name: "Test")]
        try expect(restarted.selectedEffort == nil) // A refreshed catalog can remove an effort.

        library.defaultModel = "plain"
        try expect(library.defaultEffort == nil)
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        try expect(library.selectedModel == "plain" && library.selectedEffort == nil)
        library.defaultModel = "removed-model"
        library.defaultEffort = "unsupported"
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        try expect(library.selectedModel == "test" && library.selectedEffort == nil)
        try expect(library.defaultModel == "removed-model") // Retain the preference across catalog changes.

        // First launch without a saved session also honors defaults after discovery.
        for model in ["test", ""] {
            preferences.set(model, forKey: "defaultSessionModel")
            preferences.set("high", forKey: "defaultSessionEffort")
            let fresh = try ChatLibrary(provider: provider,
                                        sessions: SessionStore(directory: root.appendingPathComponent(UUID().uuidString)),
                                        preferences: preferences)
            fresh.restore()
            try await wait { !fresh.hasRunningOperations }
            try expect(fresh.selectedModel == "test" && fresh.selectedEffort == "high")
            fresh.stopAll()
        }

        try await newSessionDefaults(provider: provider, root: root, preferences: preferences)

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved!)) as! [String: Any]
        legacy.removeValue(forKey: "effort")
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        try expect(decoded.effort == nil)
    }

    private func newSessionDefaults(provider: FakeProvider, root: URL, preferences: UserDefaults) async throws {
        let sessions = SessionStore(directory: root.appendingPathComponent("defaults"))
        let library = try ChatLibrary(provider: provider, sessions: sessions, preferences: preferences)
        try expect(library.defaultAutoApproveTools) // Preserve the existing installation default.
        library.restore()
        try await wait { !library.hasRunningOperations }
        library.defaultModel = "test"
        library.defaultEffort = "high"
        library.defaultAutoApproveTools = false
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        library.selectWorkspace(root)
        try await wait { !library.hasRunningOperations }
        try expect(!library.autoApproveTools) // Picking a workspace must not enable auto mode.
        let workspace = library.workspace
        library.selectedModel = "plain"
        library.setAutoApproveTools(true)
        let original = library.current
        let originalID = library.currentSessionID!
        await original.waitForPendingSave()

        library.newConversation()
        try await wait { !library.hasRunningOperations }
        try expect(library.workspace?.root == workspace?.root)
        try expect(library.selectedModel == "test" && library.selectedEffort == "high")
        try expect(!library.autoApproveTools)
        try expect(original.selectedModel == "plain" && original.autoApproveTools)
        let snapshot = try await sessions.load(id: library.currentSessionID!)
        try expect(snapshot?.selectedModel == "test" && snapshot?.effort == "high" && snapshot?.autoApproveTools == false)

        library.selectedEffort = "low"
        library.defaultAutoApproveTools = true
        try expect(!library.autoApproveTools) // Changing defaults leaves the current session alone.
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        try expect(library.workspace?.root == workspace?.root && library.autoApproveTools)
        try expect(library.selectedEffort == "high")
        library.defaultAutoApproveTools = false
        let restarted = try ChatLibrary(provider: provider, sessions: sessions, preferences: preferences)
        try expect(!restarted.defaultAutoApproveTools)
        restarted.restore()
        try await wait { !restarted.hasRunningOperations }
        try expect(restarted.autoApproveTools) // Saved sessions retain their own choices.
        restarted.openSession(originalID)
        try await wait { !restarted.hasRunningOperations }
        try expect(restarted.selectedModel == "plain" && restarted.autoApproveTools)
        restarted.newConversation()
        try await wait { !restarted.hasRunningOperations }
        try expect(restarted.workspace?.root == workspace?.root && !restarted.autoApproveTools)
        try expect(restarted.selectedModel == "test" && restarted.selectedEffort == "high")
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Effort operation did not settle")
    }
}
