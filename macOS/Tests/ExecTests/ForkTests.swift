import AppKit
import SwiftUI

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

    func forksRunningTurnsAndPreservesSourceOnFailure() async throws {
        try await forksStreamingResponseWithoutWaiting()
        try await forksCompletedToolResultsWithoutWaiting()
        try await forksDuringCompaction()
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let library = fixture.library
        let source = library.current
        let count = fixture.provider.children.count
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

    private func forksStreamingResponseWithoutWaiting() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let library = fixture.library
        let source = library.current
        let provider = fixture.provider.children.last!
        let original = try await fixture.sessions.load(id: source.currentSessionID!)!
        provider.runner.holdOpen = true
        source.draft = "Still running"
        library.send()
        for _ in 0..<500 {
            if provider.runner.pending != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(source.busy && library.canForkConversation(source))
        source.draft = "Queued input"
        source.send()
        source.draft = "/fork"
        library.forkConversation(source)
        for _ in 0..<500 {
            if library.current !== source { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let fork = library.current
        try expect(fork !== source && source.busy && !source.isStopping)
        try expect(fork.messages == original.messages + [source.messages[original.messages.count]])
        try expect(fork.pendingInput.isEmpty && fork.draft.isEmpty)
        let saved = try await fixture.sessions.load(id: fork.currentSessionID!)!
        try expect(saved.history == provider.runner.inputs.last)
        try expect(saved.providerState == original.providerState)
        try expect(!saved.activeTurn && saved.activeCallID == nil)
        try expect(source.pendingInput.count == 1 && source.draft.isEmpty)
        source.stop()
        await source.waitUntilIdle()
        provider.runner.pending?.finish()
    }

    private func forksCompletedToolResultsWithoutWaiting() async throws {
        let provider = FakeProvider()
        let calls = ["finished", "running", "queued"].map {
            ToolCall(id: $0, name: "fetch_content", arguments: "{\"url\":\"https://example.com/\($0)\"}")
        }
        provider.scripted = [calls.map(ChatEvent.toolCall) + [.completed]]
        var started = 0
        let source = ChatStore(provider: provider, newConversation: true, fetchContent: { _ in
            let number = await MainActor.run { started += 1; return started }
            if number == 1 { return "Completed page" }
            while true { try await Task.sleep(for: .milliseconds(5)) }
        })
        source.selectedModel = "test"
        source.draft = "Fetch pages"
        source.send()
        for _ in 0..<500 {
            if started == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(started == 2 && source.canFork)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let forkProvider = FakeProvider()
        let fork = ChatStore(provider: forkProvider, sessions: sessions, newConversation: true)
        try fork.copyConversation(from: source)
        try await fork.saveIfIdle(force: true)
        let saved = try await sessions.load(id: fork.currentSessionID!)!
        try expect(source.busy && !source.isStopping && started == 2)
        try expect(fork.error == nil && !fork.busy && fork.pendingInput.isEmpty)
        try expect(fork.messages.allSatisfy { $0.status == .complete && $0.pendingTool == nil })
        try expect(fork.messages.compactMap(\.toolResult).map(\.text) == ["Completed page"])
        let outcomes = saved.history.compactMap(\.toolResult)
        try expect(outcomes.map(\.call.id) == calls.map(\.id))
        try expect(outcomes[0].text == "Completed page")
        try expect(outcomes.dropFirst().allSatisfy { $0.text.contains("may still be running") })
        try expect(forkProvider.inputs.isEmpty)
        source.stop()
        await source.waitUntilIdle()
    }

    private func forksDuringCompaction() async throws {
        let provider = FakeProvider()
        let source = ChatStore(provider: provider, newConversation: true)
        source.selectedModel = "test"
        source.draft = "Original input"
        source.send()
        await source.waitUntilIdle()
        let original = source.messages
        var started = false
        provider.manualCompactionAction = { _ in
            started = true
            while true { try await Task.sleep(for: .milliseconds(5)) }
        }
        source.compact()
        for _ in 0..<500 {
            if started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(started && source.canFork)
        let fork = ChatStore(provider: FakeProvider(), newConversation: true)
        try fork.copyConversation(from: source)
        try expect(source.busy && !source.isStopping && fork.messages == original)
        try expect(fork.error == nil && !fork.busy)
        source.stop()
        await source.waitUntilIdle()
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

    private struct RenderedFork: View {
        let library: ChatLibrary
        let windows: SessionWindows
        @FocusState private var focused: Bool
        var body: some View {
            ChatWindowLayout(initiallyShowsSidebar: true) { Text("Synthetic sessions") } detail: {
                ConversationView(library: library, conversation: library.current,
                    presentation: windows.presentation(for: library.current), focused: $focused)
                    .id(ObjectIdentifier(library.current))
            }
        }
    }

    func coldForkAndJumpsHaveLaidOutText() async throws {
        _ = NSApplication.shared
        let sourceText = String(repeating: "A paragraph of normal **formatted** text.\n\n", count: 60)
        let messages = (0..<120).map { Message(role: $0.isMultiple(of: 2) ? .user : .assistant, text: sourceText) }
        let fixture = try await Fixture(messages: messages)
        defer { fixture.cleanUp() }
        let library = fixture.library
        let windows = SessionWindows(library: library)
        let source = library.current
        let sourceState = windows.presentation(for: source)
        let controller = NSHostingController(rootView: RenderedFork(library: library, windows: windows))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 980, height: 700))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        func settleWindow() async throws {
            for _ in 0..<12 {
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        func texts(in view: NSView) -> [LinkedText.TextView] {
            if let text = view as? LinkedText.TextView { return [text] }
            return view.subviews.flatMap { texts(in: $0) }
        }
        func checkRows(_ view: TranscriptScrollView) throws {
            for row in view.documentView!.subviews {
                for text in texts(in: row) {
                    try expect(text.textLayoutManager == nil)
                    let used = text.layoutManager!.usedRect(for: text.textContainer!)
                    let frame = text.convert(text.bounds, to: row)
                    try expect(abs(ceil(used.height) - frame.height) < 1)
                    try expect(frame.minY >= 0 && frame.maxY <= row.bounds.height)
                }
            }
        }
        try await settleWindow()
        sourceState.scrollView!.contentView.scroll(to: NSPoint(x: 0, y: 200))
        sourceState.expanded[messages[0].id] = true
        windows.forkConversation(source)
        try await settle(library)
        try await settleWindow()
        let state = windows.presentation(for: library.current)
        let view = state.scrollView!
        try expect(state !== sourceState && state.expanded.isEmpty && state.followsLatest)
        try expect(library.current.messages == messages && source.messages == messages)
        try expect(fixture.provider.children.allSatisfy { $0.runner.inputs.isEmpty })
        for width: CGFloat in [980, 720] {
            window.setContentSize(NSSize(width: width, height: 700))
            try await settleWindow()
            try checkRows(view)
            let doc = view.documentView!
            let lastRow = doc.subviews.max { $0.frame.maxY < $1.frame.maxY }!
            let text = texts(in: lastRow).last!
            let used = text.layoutManager!.usedRect(for: text.textContainer!)
            let end = text.convert(NSPoint(x: 0, y: used.maxY), to: doc).y
            let inset = doc.bounds.height - state.layout.totalHeight
            try expect(state.followsLatest && abs(view.contentView.bounds.maxY - doc.bounds.height) < 1)
            try expect(end > view.contentView.bounds.minY && end <= view.contentView.bounds.maxY - inset)
            let bottom = view.contentView.bounds.minY
            for y in stride(from: lastRow.frame.minY, through: bottom, by: CGFloat(150)) {
                view.contentView.scroll(to: NSPoint(x: 0, y: y))
                view.refresh(); controller.view.layoutSubtreeIfNeeded()
            }
            state.jumpToLatest()
            view.update(messages: messages, jumpRequest: state.jumpRequest, bottomInset: inset)
            try await settleWindow()
            try expect(text.layoutManager!.usedRect(for: text.textContainer!) == used)
            for _ in 0..<3 {
                view.navigateSentMessage(.previous)
                try await settleWindow()
                try checkRows(view)
                let target = state.layout.offsets.firstIndex { abs($0 - view.contentView.bounds.minY - 20) < 1 }
                try expect(target.map { messages[$0].role == .user } == true)
            }
            state.jumpToLatest()
            view.update(messages: messages, jumpRequest: state.jumpRequest, bottomInset: inset)
            try await settleWindow()
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

        init(messages: [Message]? = nil) async throws {
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
            let history = messages ?? [user, assistant, tool, Message(role: .assistant, text: "Completed answer")]
            let transcript = messages ?? (history + [Message(role: .assistant, text: "Compacted", compaction: .manual),
                                         Message(role: .assistant, text: "Interrupted answer", status: .interrupted)])
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
