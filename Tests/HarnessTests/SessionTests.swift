import Foundation

@MainActor struct SessionTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func conversationAndWorkspaceSurviveRestart() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let initialProvider = FakeProvider()
        initialProvider.account = nil
        let first = ChatStore(provider: initialProvider, sessions: sessions)
        first.connect()
        try await settle(first)
        first.draft = "Initial sign-in"
        first.send()
        try await settle(first)
        try expect(first.error == nil)
        first.selectWorkspace(root)
        try await settle(first)
        first.selectedModel = "test"
        first.draft = "First"
        first.send()
        try await settle(first)
        try expect(first.error == nil)
        let messageID = first.messages.first!.id
        let provider = FakeProvider()
        let restarted = ChatStore(provider: provider, sessions: sessions)
        restarted.restore()
        try await settle(restarted)
        try expect(provider.inputs.isEmpty)
        try expect(restarted.messages.first?.id == messageID)
        try expect(restarted.workspace?.root == first.workspace?.root)
        try expect(restarted.selectedModel == "test")
        restarted.draft = "Follow-up"
        restarted.send()
        try await settle(restarted)
        try expect(provider.inputs.last?.map(\.text) == ["First", "Hello world", "Follow-up"])
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("sessions/session.json").path)
        try expect(permissions[.posixPermissions] as? Int == 0o600)
        restarted.newConversation()
        try await settle(restarted)
        let cleared = try await sessions.load()
        try expect(cleared?.history.isEmpty == true && cleared?.messages.isEmpty == true)
    }

    func interruptedActionsAreRecordedNotReplayed() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let user = Message(role: .user, text: "Change something")
        let active = ToolCall(id: "active", name: "shell", arguments: #"{"command":"printf x >> effect"}"#)
        let waiting = ToolCall(id: "waiting", name: "shell", arguments: #"{"command":"touch unexpected"}"#)
        let assistant = Message(role: .assistant, text: "", toolCalls: [active, waiting])
        let snapshot = SessionSnapshot(identity: "test@example.com", workspace: try Workspace.load(root), selectedModel: "test",
                                       messages: [user, assistant], history: [user, assistant], providerState: nil,
                                       activeTurn: true, activeCallID: active.id)
        try await sessions.save(snapshot)
        // Simulate the command taking effect before its result could be saved.
        try "x".write(to: root.appendingPathComponent("effect"), atomically: true, encoding: .utf8)
        let provider = FakeProvider()
        let restored = ChatStore(provider: provider, sessions: sessions)
        restored.restore()
        try await settle(restored)
        try expect(provider.inputs.isEmpty && restored.tools.pendingApproval == nil)
        try expect(restored.error?.contains("interrupted") == true)
        try expect(restored.messages.contains { $0.toolResult?.call.id == active.id && $0.text.contains("may have changed files") })
        try expect(restored.messages.contains { $0.toolResult?.call.id == waiting.id && $0.text.contains("Not executed") })
        let saved = try await sessions.load()
        try expect(saved?.activeTurn == false && saved?.activeCallID == nil)
        restored.draft = "What happened?"
        restored.send()
        try await settle(restored)
        try expect(provider.inputs.last?.filter { $0.role == .tool }.count == 2)
        try expect(try String(contentsOf: root.appendingPathComponent("effect"), encoding: .utf8) == "x")
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))

        let approvalCall = ToolCall(id: "approval-check", name: "shell", arguments: #"{"command":"touch unexpected"}"#)
        provider.scripted = [[.toolCall(approvalCall), .completed]]
        restored.draft = "Ask for approval"
        restored.send()
        for _ in 0..<400 {
            if restored.tools.pendingApproval != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(restored.tools.pendingApproval != nil)
        let journal = try await sessions.load()
        try expect(journal?.activeCallID == approvalCall.id && journal?.activeTurn == true)
        try expect(journal?.history.last?.toolCalls.first?.id == approvalCall.id)
        restored.stop()
        try await settle(restored)
        let finished = try await sessions.load()
        try expect(finished?.activeTurn == false)
        try expect(finished?.history.contains { $0.toolResult?.call.id == approvalCall.id && $0.text.contains("Interrupted") } == true)

        // Partial text is visible after recovery but never promoted into history.
        var partial = snapshot
        partial.messages = [user, Message(role: .assistant, text: "partial", status: .streaming)]
        partial.history = []; partial.activeCallID = nil
        _ = partial.recoverInterruptedTurn()
        try expect(partial.messages.last?.status == .interrupted && partial.history.isEmpty)
    }

    func incompatibleOrCorruptSessionsAreNotOverwritten() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let snapshot = SessionSnapshot(identity: "another-account", selectedModel: "test", messages: [], history: [], activeTurn: false)
        try await sessions.save(snapshot)
        let file = root.appendingPathComponent("session.json")
        let original = try Data(contentsOf: file)
        let provider = FakeProvider()
        let store = ChatStore(provider: provider, sessions: sessions)
        store.restore()
        try await settle(store)
        try expect(store.error?.contains("another account") == true && provider.inputs.isEmpty)
        try expect(try Data(contentsOf: file) == original)
        try Data("corrupt".utf8).write(to: file)
        store.restore()
        try await settle(store)
        try expect(store.error?.contains("Could not restore") == true)
        try expect(try Data(contentsOf: file) == Data("corrupt".utf8))
        store.newConversation()
        try await settle(store)
        let cleared = try await sessions.load()
        try expect(cleared?.identity == provider.conversationIdentity && cleared?.history.isEmpty == true)
    }

    func failedCheckpointPreventsModelAndToolExecution() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions")
        let provider = FakeProvider()
        let store = ChatStore(provider: provider, sessions: SessionStore(directory: directory))
        store.selectWorkspace(root)
        try await settle(store)
        store.restore()
        try await settle(store)
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)
        store.draft = "Do something"
        store.send()
        try await settle(store)
        try expect(store.error?.contains("Could not save") == true)
        try expect(provider.inputs.isEmpty && store.tools.pendingApproval == nil)

        // Also fail the checkpoint after a model has requested a side effect.
        try FileManager.default.removeItem(at: directory)
        store.restore()
        try await settle(store)
        var injectedError: Error?
        provider.onSend = {
            do {
                try FileManager.default.removeItem(at: directory)
                try Data("blocked".utf8).write(to: directory)
            } catch { injectedError = error }
        }
        provider.scripted = [[.toolCall(ToolCall(id: "unsafe", name: "shell", arguments: #"{"command":"touch unexpected"}"#)), .completed]]
        store.draft = "Request a tool"
        store.send()
        try await settle(store)
        try expect(injectedError == nil && provider.inputs.count == 1)
        try expect(store.error?.contains("Could not save") == true && store.tools.pendingApproval == nil)
    }

    private func settle(_ store: ChatStore) async throws {
        for _ in 0..<400 {
            if !store.busy { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Session operation did not settle")
    }
}
