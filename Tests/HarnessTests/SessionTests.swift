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
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("sessions/\(restarted.currentSessionID!).json").path)
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
        var snapshot = SessionSnapshot(identity: "another-account", selectedModel: "test", messages: [], history: [], activeTurn: false)
        let foreignID = try await sessions.save(snapshot)
        let file = root.appendingPathComponent("\(foreignID).json")
        let original = try Data(contentsOf: file)
        let provider = FakeProvider()
        let store = ChatStore(provider: provider, sessions: sessions)
        store.restore()
        try await settle(store)
        try expect(store.sessionList.isEmpty && provider.inputs.isEmpty)
        store.openSession(foreignID)
        try await settle(store)
        try expect(store.error?.contains("another account") == true)
        try expect(try Data(contentsOf: file) == original)
        snapshot.identity = provider.conversationIdentity
        let corruptID = try await sessions.save(snapshot, id: UUID())
        let corruptFile = root.appendingPathComponent("\(corruptID).json")
        try Data("corrupt".utf8).write(to: corruptFile)
        let previousID = store.currentSessionID
        store.openSession(corruptID)
        try expect(store.sidebarSelectionID == corruptID && store.currentSessionID == previousID)
        try await settle(store)
        try expect(store.error != nil && store.messages.isEmpty)
        try expect(store.openingSessionID == nil && store.sidebarSelectionID == previousID)
        store.newConversation()
        try await settle(store)
        try expect(try Data(contentsOf: corruptFile) == Data("corrupt".utf8))
        try expect(try Data(contentsOf: file) == original)
        store.deleteSession(corruptID)
        try await settle(store)
        try expect(!FileManager.default.fileExists(atPath: corruptFile.path))
    }

    func sessionsSwitchDeleteAndMigrateWithoutLosingHistory() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let user = Message(role: .user, text: "Legacy conversation")
        let assistant = Message(role: .assistant, text: "Saved answer")
        let legacy = SessionSnapshot(identity: "test@example.com", selectedModel: "test", messages: [user, assistant], history: [user, assistant], activeTurn: false)
        try JSONEncoder().encode(legacy).write(to: root.appendingPathComponent("session.json"))
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        let store = ChatStore(provider: provider, sessions: sessions)
        store.restore()
        try await settle(store)
        let legacyID = store.currentSessionID!
        try expect(store.messages.first?.id == user.id && store.sessionList.count == 1)
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("session.json").path))
        store.newConversation()
        try await settle(store)
        store.draft = "Separate conversation"
        store.send()
        try await settle(store)
        let secondID = store.currentSessionID!
        try expect(secondID != legacyID && store.sessionList.count == 2)
        try expect(provider.inputs.last?.map(\.text) == ["Separate conversation"])
        let order = store.sessionList.map(\.id)
        let dates = store.sessionList.map(\.updatedAt)
        store.openSession(legacyID)
        try expect(store.busy && store.sidebarSelectionID == legacyID)
        try expect(store.currentSessionID == secondID && store.messages.first?.text == "Separate conversation")
        // A second navigation cannot replace the in-flight selection or its conversation.
        store.openSession(secondID)
        try expect(store.sidebarSelectionID == legacyID)
        try await settle(store)
        try expect(store.openingSessionID == nil && store.sidebarSelectionID == legacyID)
        try expect(store.currentSessionID == legacyID && store.messages.first?.id == user.id)
        let selected = try await sessions.preferredID(identity: provider.conversationIdentity)
        try expect(selected == legacyID)
        try expect(store.sessionList.map(\.id) == order)
        try expect(store.sessionList.map(\.updatedAt) == dates)
        store.draft = "Continue legacy"
        store.send()
        try await settle(store)
        try expect(provider.inputs.last?.map(\.text) == ["Legacy conversation", "Saved answer", "Continue legacy"])
        store.deleteSession(secondID)
        try await settle(store)
        try expect(store.currentSessionID == legacyID && store.sessionList.count == 1)
        store.deleteSession(legacyID)
        try await settle(store)
        try expect(store.messages.isEmpty && store.workspace == nil && store.sessionList.isEmpty)
        let restarted = SessionStore(directory: root)
        let remaining = try await restarted.list(identity: provider.conversationIdentity)
        try expect(remaining.isEmpty)
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("\(legacyID).json").path))
    }

    func indexRecoveryDoesNotReplayOrResurrectDeletedSessions() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let snapshot = SessionSnapshot(identity: "test", selectedModel: "test", messages: [Message(role: .user, text: "Recover me")], history: [], activeTurn: true, activityDate: Date(timeIntervalSince1970: 100))
        let id = try await sessions.save(snapshot)
        try await sessions.rename(id: id, title: "Recovered name", identity: "test")
        try await sessions.save(snapshot, id: id, select: false) // A running turn's older snapshot must retain the name.
        let staleIndex = try Data(contentsOf: root.appendingPathComponent("index.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("index.json"))
        let recovered = SessionStore(directory: root)
        let list = try await recovered.list(identity: "test")
        try expect(list.count == 1 && list.first?.id == id)
        try expect(list.first?.updatedAt == snapshot.activityDate)
        try expect(list.first?.title == "Recovered name")
        let loaded = try await recovered.load(id: id)
        try expect(loaded?.activeTurn == true) // Storage itself never executes or normalizes operations.
        try await recovered.delete(id: id)
        // Simulate termination after unlink but before the index write completed.
        try staleIndex.write(to: root.appendingPathComponent("index.json"))
        let afterDeletion = SessionStore(directory: root)
        let remaining = try await afterDeletion.list(identity: "test")
        try expect(remaining.isEmpty)
        let active = try await afterDeletion.load()
        try expect(active == nil)
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
