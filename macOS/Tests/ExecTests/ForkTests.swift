import Foundation

@MainActor struct ForkTests {
    func copiesContextAndSettingsIndependently() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let library = fixture.library
        let source = library.current
        let sourceID = source.currentSessionID!
        let original = try await fixture.sessions.load(id: sourceID)!
        let sourceProvider = fixture.provider.children.last!
        source.draft = "/fo"
        source.draftImages = [fixture.image]
        let windows = SessionWindows(library: library)
        windows.forkConversation(source)
        try await settle(library)
        let fork = library.current
        let forkID = fork.currentSessionID!
        let forkProvider = fixture.provider.children.last!
        try expect(fork !== source && forkID != sourceID && forkProvider !== sourceProvider)
        try expect(fork.messages == original.messages && source.messages == original.messages)
        try expect(fork.selectedModel == "test" && fork.selectedEffort == "high")
        try expect(!fork.autoApproveTools && fork.workspace?.root == source.workspace?.root)
        try expect(fork.workspace?.instructions == source.workspace?.instructions)
        try expect(fork.systemPrompt == "Shared instructions" && fork.searchModel == "test")
        try expect(forkProvider.state == original.providerState && forkProvider.restoredHistory == original.history)
        try expect(forkProvider.runner.inputs.isEmpty && sourceProvider.runner.inputs.isEmpty)
        try expect(fork.draft.isEmpty && fork.draftImages.isEmpty && source.draft.isEmpty)
        try expect(source.draftImages == [fixture.image] && !fork.needsInitialWorkspaceSelection)
        try expect(windows.sidebarRevealRequest == 1 && windows.composerFocusRequest == 1)
        let saved = try await fixture.sessions.load(id: forkID)!
        try expect(saved.messages == original.messages && saved.history == original.history)
        try expect(saved.providerState == original.providerState && saved.effort == "high")
        try expect(saved.autoApproveTools == false && !saved.activeTurn && saved.activeCallID == nil)
        let selectedID = try await fixture.sessions.preferredID(identity: fixture.provider.conversationIdentity)
        try expect(selectedID == forkID)

        fork.draft = "Continue differently"
        library.send()
        try await settle(library)
        try expect(forkProvider.runner.inputs.last == original.history + [fork.messages[original.messages.count]])
        try expect(forkProvider.runner.efforts == ["high"])
        try expect(source.messages == original.messages && sourceProvider.state == original.providerState)
        try expect(forkProvider.state != sourceProvider.state)
        let unchanged = try await fixture.sessions.load(id: sourceID)!
        try expect(unchanged.messages == original.messages && unchanged.providerState == original.providerState)

        // The copied provider context survives a cold load, not just the resident runner.
        let restoredProvider = ForkProvider()
        let restored = ChatStore(provider: restoredProvider, sessions: fixture.sessions, newConversation: true)
        restored.models = fixture.provider.runner.availableModels
        try await restored.loadSession(forkID)
        try expect(restored.messages == fork.messages && restoredProvider.state == forkProvider.state)
        try expect(restoredProvider.runner.inputs.isEmpty)
    }

    func rejectsRunningTurnsAndPreservesSourceOnFailure() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let library = fixture.library
        let source = library.current
        let provider = fixture.provider.children.last!
        provider.runner.holdOpen = true
        source.draft = "Still running"
        library.send()
        for _ in 0..<500 {
            if provider.runner.pending != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(source.busy && !library.canForkConversation(source))
        let count = fixture.provider.children.count
        library.forkConversation(source)
        try expect(fixture.provider.children.count == count && library.current === source)
        source.stop()
        await source.waitUntilIdle()
        provider.runner.pending?.finish()
        try await settle(library)

        source.draft = "/fork"
        let original = source.messages
        fixture.provider.failRestore = true
        library.forkConversation(source)
        try await settle(library)
        try expect(library.current === source && source.draft == "/fork" && source.messages == original)
        try expect(source.error == "Cannot restore test context" && library.sessionList.count == 1)
        try expect(fixture.provider.children.count == count + 1) // No automatic retry.
        fixture.provider.failRestore = false

        // A storage failure must not switch selection or discard the source command.
        let storeURL = fixture.root.appendingPathComponent("sessions")
        try FileManager.default.moveItem(at: storeURL, to: fixture.root.appendingPathComponent("saved-sessions"))
        try Data("blocked".utf8).write(to: storeURL)
        library.forkConversation(source)
        try await settle(library)
        try expect(library.current === source && source.draft == "/fork" && source.messages == original)
        try expect(source.error?.contains("Could not save") == true)
    }

    func detachedForkAndDeletionRetainInheritedAssets() async throws {
        for deleteOriginalFirst in [true, false] {
            let fixture = try await Fixture()
            defer { fixture.cleanUp() }
            let library = fixture.library
            let source = library.current
            let sourceID = source.currentSessionID!
            let logDirectory = try await fixture.sessions.prepareShellLogDirectory(id: sourceID)
            let log = logDirectory.appendingPathComponent("output.log")
            try Data("Full shell output".utf8).write(to: log)
            let imageURL = try await fixture.sessions.saveImage(fixture.image)
            let generatedURL = try await fixture.sessions.saveImage(fixture.generatedImage)
            library.detachSession(sourceID) { _ in }
            try expect(library.current !== source)
            source.draft = "/fork"
            let windows = SessionWindows(library: library)
            windows.forkConversation(source)
            try await settle(library)
            let firstFork = library.current
            let firstID = firstFork.currentSessionID!
            try expect(firstFork !== source && firstFork.messages == source.messages)
            try expect(library.detachedSessionIDs.contains(sourceID))
            let branchLogs = try await fixture.sessions.prepareShellLogDirectory(id: firstID)
            try Data("Branch output".utf8).write(to: branchLogs.appendingPathComponent("branch.log"))
            windows.forkConversation(firstFork)
            try await settle(library)
            let secondID = library.current.currentSessionID!
            let restarted = SessionStore(directory: fixture.root.appendingPathComponent("sessions"))
            let order = deleteOriginalFirst ? [sourceID, firstID, secondID] : [secondID, firstID, sourceID]
            for id in order.dropLast() {
                try await restarted.delete(id: id)
                try expect(String(contentsOf: log, encoding: .utf8) == "Full shell output")
                try expect(Data(contentsOf: imageURL) == fixture.image.data)
                try expect(Data(contentsOf: generatedURL) == fixture.generatedImage.data)
            }
            let saved = try await restarted.load(id: order.last!)!
            try expect(saved.messages.first?.images == [fixture.image])
            try expect(saved.messages.compactMap { $0.toolResult?.generatedImage } == [fixture.generatedImage])
            // A fork's own logs are retained by its descendants, but not its parent.
            try expect(FileManager.default.fileExists(atPath: branchLogs.path) == deleteOriginalFirst)
            try await restarted.delete(id: order.last!)
            for url in [logDirectory, branchLogs, imageURL, generatedURL] {
                try expect(!FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    private func settle(_ library: ChatLibrary) async throws {
        for _ in 0..<500 {
            if !library.hasRunningOperations { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Fork operation did not settle")
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferenceID = "ForkTests-" + UUID().uuidString
        let preferences: UserDefaults
        let sessions: SessionStore
        let provider = ForkProvider()
        let library: ChatLibrary
        let image = ImageAttachment(name: "attachment.png", mediaType: "image/png", data: Data([1, 2, 3]))
        let generatedImage = ImageAttachment(name: "generated.png", mediaType: "image/png", data: Data([4, 5, 6]))

        init() async throws {
            preferences = UserDefaults(suiteName: preferenceID)!
            preferences.set(false, forKey: "generatedTitlesEnabled")
            preferences.set("Shared instructions", forKey: "systemPrompt")
            preferences.set("test", forKey: "searchModel")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
            let user = Message(role: .user, text: "Original prompt", images: [image])
            let call = ToolCall(id: "old-tool", name: "generate_image", arguments: "{}")
            let assistant = Message(role: .assistant, text: "", toolCalls: [call])
            let tool = Message(role: .tool, text: "Old result",
                               toolResult: ToolResult(call: call, text: "Old result", generatedImage: generatedImage))
            let history = [user, assistant, tool, Message(role: .assistant, text: "Completed answer")]
            let transcript = history + [Message(role: .assistant, text: "Compacted", compaction: .manual),
                                        Message(role: .assistant, text: "Interrupted answer", status: .interrupted)]
            try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity,
                workspace: Workspace(root: try Workspace.load(root).root, instructions: "Original workspace instructions"),
                selectedModel: "test", messages: transcript, history: history,
                providerState: Data("opaque compacted reasoning".utf8), activeTurn: false,
                effort: "high", autoApproveTools: false), id: UUID())
            library = try ChatLibrary(provider: provider, sessions: sessions, preferences: preferences)
            library.restore()
            try await ForkTests().settle(library)
        }

        func cleanUp() {
            library.stopAll()
            preferences.removePersistentDomain(forName: preferenceID)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

@MainActor private final class ForkProvider: ChatProvider {
    let displayName = "Fork Test"
    let connectionTitle = "Test only"
    let account: String? = "isolated-account"
    let runner = FakeProvider()
    var state: Data?
    var restoredHistory: [Message] = []
    var failRestore = false
    var children: [ForkProvider] = []

    init() {
        runner.availableModels = [ChatModel(id: "test", name: "Test", efforts: [.init(id: "high", name: "High")])]
    }
    func makeConversationProvider() throws -> any ChatProvider {
        let child = ForkProvider()
        child.failRestore = failRestore
        children.append(child)
        return child
    }
    func encodeConversationState() throws -> Data? { state }
    func restoreConversationState(_ data: Data?, history: [Message]) throws {
        if failRestore { throw ExecError("Cannot restore test context") }
        state = data
        restoredHistory = history
    }
    func connect() async throws {}
    func disconnect() async throws {}
    func models() async throws -> [ChatModel] { runner.availableModels }
    func send(_ messages: [Message], model: String, effort: String?, instructions: String,
              tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error> {
        state = Data("new branch context".utf8)
        return runner.send(messages, model: model, effort: effort, instructions: instructions, tools: tools)
    }
}
