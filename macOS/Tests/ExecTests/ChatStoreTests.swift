import Foundation

@MainActor final class FakeConnection {
    var account: String? = "test@example.com"
}

@MainActor final class FakeProvider: ChatProvider {
    let displayName = "Test"
    let connectionTitle = "Connect to Test"
    private let connection: FakeConnection
    var account: String? {
        get { connection.account }
        set { connection.account = newValue }
    }
    var children: [FakeProvider] = []
    var usageAction: (() async throws -> AccountUsage?)?
    func accountUsage() async throws -> AccountUsage? { try await usageAction?() }
    var supportsCompaction: Bool { true }
    var manualCompactionAction: (([Message]) async throws -> Void)?
    func compact(_ history: [Message], model: ChatModel, instructions: String, tools: [ToolDefinition]) async throws {
        try await manualCompactionAction?(history)
    }
    var compactionAction: (() throws -> Bool)?
    var compactionCompletionAction: (() throws -> Void)?
    func compactIfNeeded(_ history: [Message], pending: [Message], model: ChatModel,
                         instructions: String, tools: [ToolDefinition],
                         willCompact: @MainActor () async throws -> Void = {}) async throws -> Bool {
        guard try compactionAction?() == true else { return false }
        try await willCompact()
        try compactionCompletionAction?()
        return true
    }
    init(connection: FakeConnection = FakeConnection()) { self.connection = connection }
    func makeConversationProvider() throws -> any ChatProvider {
        let child = FakeProvider(connection: connection)
        child.availableModels = availableModels
        children.append(child)
        return child
    }
    var inputs: [[Message]] = []
    var efforts: [String?] = []
    var requestedModels: [String] = []
    var availableModels = [ChatModel(id: "test", name: "Test")]
    var instructions: [String] = []
    var scripted: [[ChatEvent]] = []
    var onSend: (() -> Void)?
    var shouldFail = false
    var holdOpen = false
    var pending: AsyncThrowingStream<ChatEvent, Error>.Continuation?

    func connect() async throws { account = "test@example.com" }
    var disconnectAction: (() async -> Void)?
    func disconnect() async throws {
        account = nil
        await disconnectAction?()
    }
    var modelsAction: (() async throws -> Void)?
    func models() async throws -> [ChatModel] {
        try await modelsAction?()
        return availableModels
    }
    func send(_ messages: [Message], model: String, effort: String?, instructions: String, tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error> {
        inputs.append(messages)
        efforts.append(effort)
        requestedModels.append(model)
        self.instructions.append(instructions)
        onSend?()
        if !scripted.isEmpty {
            let events = scripted.removeFirst()
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("Hello"))
            continuation.yield(.text(" world"))
            if holdOpen { pending = continuation }
            else if shouldFail { continuation.finish(throwing: ExecError("failed")) }
            else { continuation.yield(.completed); continuation.finish() }
        }
    }
}

@MainActor struct ChatStoreTests {
    private func settle(_ store: ChatStore) async throws {
        for _ in 0..<200 {
            if !store.busy { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ExecError("Operation did not settle")
    }

    func longToolTurnsFinishWithoutArtificialCaps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        provider.scripted = (0..<18).map { index in
            [.toolCall(ToolCall(id: "read-\(index)", name: "list_files", arguments: #"{"path":"."}"#)), .completed]
        } + [[.text("Finished"), .completed]]
        let store = ChatStore(provider: provider)
        store.selectWorkspace(root)
        try await settle(store)
        store.selectedModel = "test"
        store.draft = "Inspect"
        store.send()
        try await settle(store)
        try expect(store.error == nil && store.messages.last?.text == "Finished")
        try expect(provider.inputs.count == 19 && store.messages.filter { $0.toolResult != nil }.count == 18)

        store.newConversation()
        try await settle(store)
        let repeated = ToolCall(id: "duplicate", name: "list_files", arguments: #"{"path":"."}"#)
        provider.scripted = [[.toolCall(repeated), .completed], [.toolCall(repeated), .completed]]
        let before = provider.inputs.count
        store.draft = "Check duplicate protection"
        store.send()
        try await settle(store)
        try expect(store.error?.contains("repeated a tool call ID") == true)
        try expect(provider.inputs.count == before + 2)
        try expect(store.messages.compactMap(\.toolResult).count == 1)
        store.draft = "Explain without retrying"
        store.send()
        try await settle(store)
        try expect(provider.inputs.last?.compactMap(\.toolResult).last?.text == "Duplicate tool call ID; not executed.")
    }

    func batchedSnapshotsFlushOnFailureAndCancellation() async throws {
        let provider = FakeProvider()
        provider.scripted = [[.text("Draft"), .textSnapshot("Latest partial answer")]]
        let store = ChatStore(provider: provider)
        store.selectedModel = "test"
        store.draft = "First"
        store.send()
        try await settle(store)
        try expect(store.messages.last?.text == "Latest partial answer")
        try expect(store.messages.last?.status == .failed)

        provider.holdOpen = true
        store.draft = "Second"
        store.send()
        for _ in 0..<200 {
            if provider.pending != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(provider.pending != nil)
        provider.pending?.yield(.textSnapshot("Snapshot before stop"))
        try await Task.sleep(for: .milliseconds(10))
        store.stop()
        try await settle(store)
        try expect(store.messages.last?.text == "Snapshot before stop")
        try expect(store.messages.last?.status == .interrupted)
        provider.pending?.finish()
    }

    func finalTextReplacesDeltasAndEmptyResponsesFail() async throws {
        let provider = FakeProvider()
        provider.scripted = [[.text("Partial draft"), .textSnapshot("Final answer"), .completed], [.completed]]
        let store = ChatStore(provider: provider)
        store.selectedModel = "test"
        store.draft = "First"
        store.send()
        try await settle(store)
        try expect(store.messages.last?.text == "Final answer")
        store.draft = "Empty response"
        store.send()
        try await settle(store)
        try expect(store.error?.contains("without text or a tool call") == true)
        try expect(store.messages.last?.status == .failed)
        store.draft = "Follow-up"
        store.send()
        try await settle(store)
        try expect(provider.inputs.last?.map(\.text) == ["First", "Final answer", "Empty response", "Follow-up"])
    }

    func interruptedToolTurnRetainsResultsWithoutReexecution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "source text".write(to: root.appendingPathComponent("source"), atomically: true, encoding: .utf8)
        let provider = FakeProvider()
        let read = ToolCall(id: "read-1", name: "read_file", arguments: #"{"path":"source","start_line":1,"end_line":2}"#)
        let shell = ToolCall(id: "shell-1", name: "shell", arguments: #"{"command":"touch unexpected"}"#)
        provider.scripted = [[.toolCall(read), .toolCall(shell), .completed]]
        let store = ChatStore(provider: provider)
        store.selectedModel = "test"
        store.selectWorkspace(root)
        try await settle(store)
        store.setAutoApproveTools(false)
        store.draft = "Inspect project"
        store.send()
        for _ in 0..<200 {
            if store.tools.pendingApproval != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(store.tools.pendingApproval != nil)
        store.stop()
        try await settle(store)
        try expect(store.messages.contains { $0.toolResult?.call.id == read.id && $0.text.contains("source text") })
        try expect(store.tools.pendingApproval == nil)
        store.draft = "Continue without shell"
        store.send()
        try await settle(store)
        let context = provider.inputs.last!
        try expect(context.contains { $0.toolResult?.call.id == read.id && $0.text.contains("source text") })
        try expect(context.contains { $0.toolResult?.call.id == shell.id && $0.text.contains("Interrupted") })
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
        try expect(provider.inputs.count == 2)

        let approvedCall = ToolCall(id: "shell-2", name: "shell", arguments: #"{"command":"printf x >> effect"}"#)
        provider.scripted = [[.toolCall(approvedCall), .completed]]
        provider.shouldFail = true // The model request after the command fails.
        store.draft = "Run approved command"
        store.send()
        for _ in 0..<200 {
            if store.tools.pendingApproval != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(store.tools.pendingApproval != nil)
        store.tools.resolveApproval(id: store.tools.pendingApproval!.id, approved: true)
        try await settle(store)
        try expect(store.error == "failed")
        provider.shouldFail = false
        store.draft = "What happened?"
        store.send()
        try await settle(store)
        try expect(provider.inputs.last!.contains { $0.toolResult?.call.id == approvedCall.id && $0.text.contains("Exit code: 0") })
        try expect(try String(contentsOf: root.appendingPathComponent("effect"), encoding: .utf8) == "x")
    }

    func workspaceChangesKeepInstructionsAndHistoryIsolated() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("AGENTS.md")
        try "Project A rules".write(to: file, atomically: true, encoding: .utf8)
        let provider = FakeProvider()
        let store = ChatStore(provider: provider)
        store.selectedModel = "test"
        store.selectWorkspace(root)
        store.stop()
        try await settle(store)
        try expect(store.workspace == nil)
        store.selectWorkspace(root)
        try await settle(store)
        try expect(store.workspace?.instructions == "Project A rules")
        store.draft = "First project question"
        store.send()
        try await settle(store)
        try expect(provider.instructions.last?.contains("Project A rules") == true)
        store.draft = "Unsent project draft"

        // A failed selection must not erase the current project or conversation.
        store.selectWorkspace(root.appendingPathComponent("missing"))
        try await settle(store)
        try expect(store.error != nil && store.messages.count == 2)
        try expect(store.workspace?.instructions == "Project A rules")
        try expect(store.draft == "Unsent project draft")

        // Instructions are a snapshot until explicitly reloaded.
        try "Updated rules".write(to: file, atomically: true, encoding: .utf8)
        try expect(store.workspace?.instructions == "Project A rules")
        store.selectWorkspace(root)
        try await settle(store)
        try expect(store.messages.isEmpty && store.draft.isEmpty)
        store.draft = "Fresh question"
        store.send()
        try await settle(store)
        try expect(provider.inputs.last?.map(\.text) == ["Fresh question"])
        try expect(provider.instructions.last?.contains("Updated rules") == true)
        store.newConversation()
        try await settle(store)
        try expect(store.workspace?.instructions == "Updated rules")
        let other = root.appendingPathComponent("other-project")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        store.selectWorkspace(other)
        try await settle(store)
        try expect(store.workspace?.root.path.hasSuffix("/other-project") == true)
        try expect(store.workspace?.instructions == nil && store.messages.isEmpty)
        store.closeWorkspace()
        try await settle(store)
        try expect(store.workspace == nil && store.messages.isEmpty)
        store.draft = "Chat only"
        store.send()
        try await settle(store)
        try expect(provider.inputs.last?.map(\.text) == ["Chat only"])
        let instructions = provider.instructions.last ?? ""
        try expect(instructions.contains("fetch_content"))
        try expect(!instructions.contains("Project A rules") && !instructions.contains("Updated rules"))
        try expect(!instructions.contains(root.path) && !instructions.contains("inspect the project"))
    }

    func successfulFollowupIncludesHistoryAndNewClearsIt() async throws {
        let provider = FakeProvider()
        let store = ChatStore(provider: provider)
        store.restore()
        try await settle(store)
        store.draft = "First"
        store.send()
        // A duplicate click cannot start another turn.
        store.send()
        try await settle(store)
        try expect(provider.inputs.count == 1)
        try expect(store.messages.last?.text == "Hello world")
        store.draft = "Second"
        store.send()
        try await settle(store)
        try expect(provider.inputs.last?.map(\.text) == ["First", "Hello world", "Second"])
        store.newConversation()
        try await settle(store)
        store.draft = "Fresh"
        store.send()
        try await settle(store)
        try expect(provider.inputs.last?.map(\.text) == ["Fresh"])
    }

    func failedResponsesPreservePartialContextWithoutToolCalls() async throws {
        for incomplete in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let sessions = SessionStore(directory: root)
            let provider = FakeProvider()
            let store = ChatStore(provider: provider, sessions: sessions)
            store.selectedModel = "test"
            store.draft = "First"
            store.send()
            try await settle(store)
            if incomplete {
                provider.scripted = [[.text("Partial answer"),
                    .toolCall(ToolCall(id: "unfinished", name: "list_files", arguments: #"{"path":"."}"#))]]
            } else {
                provider.shouldFail = true
            }
            store.draft = "Now implement the fix"
            store.send()
            try await settle(store)
            try expect(store.error != nil && provider.inputs.count == 2)
            let failed = store.messages.last!
            try expect(failed.status == .failed && !failed.text.isEmpty && failed.toolCalls.isEmpty)
            try expect(store.pendingInput.isEmpty && !store.messages.contains { $0.role == .tool })
            let expected = ["First", "Hello world", "Now implement the fix", failed.text]
            let saved = try await sessions.load(id: store.currentSessionID)!
            try expect(saved.history.map(\.text) == expected)
            try expect(saved.history.last?.id == failed.id && saved.history.last?.status == .failed)
            try expect(saved.messages.last?.id == failed.id)

            // Reopening retains partial text without retrying or reviving unfinished calls.
            let restoredProvider = FakeProvider()
            let restored = ChatStore(provider: restoredProvider, sessions: sessions)
            restored.restore()
            try await settle(restored)
            try expect(restoredProvider.inputs.isEmpty)
            restored.draft = "Continue"
            restored.send()
            try await settle(restored)
            try expect(restoredProvider.inputs.last?.map(\.text) == expected + ["Continue"])
            try expect(restoredProvider.inputs.last?[3].status == .failed)

            provider.shouldFail = false
            store.draft = "Continue"
            store.send()
            try await settle(store)
            try expect(provider.inputs.count == 3)
            try expect(provider.inputs.last?.map(\.text) == expected + ["Continue"])
            try expect(provider.inputs.last?.contains { $0.id == failed.id && $0.toolCalls.isEmpty } == true)

            // Even cached terminal output must not replace a failed partial response.
            let prompt = saved.history[2]
            let output = Data(#"[{"type":"function_call","call_id":"unexecuted","name":"shell","arguments":"{}"}]"#.utf8)
            var context = CodexConversationState(outputs: [prompt.id: output])
            context.measurement = .init(inputID: prompt.id, tokens: 123)
            var partial = failed
            partial.toolCalls = [ToolCall(id: "unfinished", name: "shell", arguments: "{}")]
            for state in [context, CodexConversationState()] {
                let wire = try state.input([prompt, partial])
                try expect(wire.count == 2)
                try expect(wire[1]["content"] as? String == "[Incomplete assistant response: generation failed.]\n\n\(failed.text)")
                try expect(state.reportedTokens([prompt, partial]) == nil)
                try expect(state.lastReportedTokens([prompt, partial]) == nil)
            }
        }
    }

    func stopPreservesPartialContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        provider.holdOpen = true
        let store = ChatStore(provider: provider, sessions: sessions)
        store.selectedModel = "test"
        store.draft = "Interrupt"
        store.send()
        for _ in 0..<200 {
            if provider.pending != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(provider.pending != nil && store.isSending)
        store.draft = "A draft for the next turn"
        store.stop()
        try await settle(store)
        try expect(!store.busy && !store.isSending)
        try expect(store.draft == "A draft for the next turn")
        try expect(store.error == nil)
        try expect(store.messages.last?.status == .interrupted)
        provider.holdOpen = false
        provider.pending?.finish()
        store.draft = "Next"
        store.send()
        try await settle(store)
        try expect(provider.inputs.last?.map(\.text) == ["Interrupt", "Hello world", "Next"])
        try expect(provider.inputs.last?[1].status == .interrupted)

        let restoredProvider = FakeProvider()
        let restored = ChatStore(provider: restoredProvider, sessions: sessions)
        restored.restore()
        try await settle(restored)
        restored.draft = "Continue after restart"
        restored.send()
        try await settle(restored)
        try expect(restoredProvider.inputs.last?.map(\.text) ==
                   ["Interrupt", "Hello world", "Next", "Hello world", "Continue after restart"])
        try expect(restoredProvider.inputs.last?[1].status == .interrupted)

        // Even if a terminal server response raced with Stop, opaque output
        // must not replace the partial text or introduce unexecuted tool calls.
        let user = Message(role: .user, text: "Prompt")
        let partial = Message(role: .assistant, text: "Partial", status: .interrupted)
        let output = Data(#"[{"type":"function_call","call_id":"unexecuted","name":"shell","arguments":"{}"}]"#.utf8)
        let context = CodexConversationState(outputs: [user.id: output])
        let wire = try context.input([user, partial])
        try expect(wire.count == 2 && wire[1]["content"] as? String == "Partial")
    }
}
