import Foundation
import Observation

@MainActor struct ChatLibraryTests {
    private func autoApprovalSurvivesRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let workspace = try Workspace.load(root)
        for enabled in [false, true] {
            let original = ChatStore(provider: FakeProvider(), sessions: sessions,
                                     newConversation: true, workspace: workspace)
            try expect(original.autoApproveTools)
            original.setAutoApproveTools(enabled)
            await original.waitForPendingSave()
            let id = original.currentSessionID!
            let reopened = ChatStore(provider: FakeProvider(), sessions: sessions)
            try await reopened.loadSession(id)
            try expect(reopened.autoApproveTools == enabled)
            reopened.suspendAutoApproval()
            try await reopened.saveIfIdle(force: true)
            let restored = ChatStore(provider: FakeProvider(), sessions: sessions)
            try await restored.loadSession(id)
            try expect(restored.autoApproveTools == enabled)
        }
    }

    func startupCatalogPrecedesModelDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        var ids: [UUID] = []
        for text in ["First", "Second", "Third"] {
            let messages = [Message(role: .user, text: text)]
            ids.append(try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity,
                selectedModel: "test", messages: messages, history: messages, activeTurn: false),
                id: UUID(), select: false))
        }
        try await sessions.select(ids[0])
        let expected = try await sessions.list(identity: provider.conversationIdentity).map(\.id)
        let library = try ChatLibrary(provider: provider, sessions: sessions)
        var pending: CheckedContinuation<Void, Never>?
        provider.children.last!.modelsAction = {
            await withCheckedContinuation { pending = $0 }
        }
        defer { pending?.resume(); library.stopAll() }
        library.restore()
        try await wait { pending != nil }
        try expect(library.authenticating)
        try expect(library.currentSessionID == ids[0])
        try expect(library.sidebarSessions.map(\.id) == expected)
        pending?.resume()
        pending = nil
        try await wait { !library.hasRunningOperations }
        try expect(library.sidebarSessions.map(\.id) == expected)
    }

    func concurrentTurnsKeepContextDraftsAndSelectionIsolated() async throws {
        try await startupCatalogPrecedesModelDiscovery()
        try await autoApprovalSurvivesRelaunch()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: sessions)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        let first = library.current
        let firstProvider = provider.children.last!
        firstProvider.holdOpen = true
        library.draft = "First request"
        library.send()
        try await wait { firstProvider.pending != nil }
        let firstID = library.currentSessionID!
        try expect(library.isSessionResponding(firstID))
        library.draft = "Unsent next request"

        library.newConversation()
        try await wait { !library.navigating }
        try expect(first.busy && first.draft == "Unsent next request")
        let second = library.current
        let secondProvider = provider.children.last!
        secondProvider.holdOpen = true
        library.draft = "Second request"
        library.send()
        try await wait { secondProvider.pending != nil }
        let secondID = library.currentSessionID!
        try expect(first.busy && second.busy && firstID != secondID)
        library.renameSession(firstID, title: "Renamed while running")
        try await wait { !library.navigating }
        try expect(first.busy && second.busy)
        try expect(library.sessionList.first(where: { $0.id == firstID })?.title == "Renamed while running")
        try expect(firstProvider.inputs[0].map(\.text) == ["First request"])
        try expect(secondProvider.inputs[0].map(\.text) == ["Second request"])
        library.disconnect() // Account-wide changes cannot invalidate either running turn.
        library.deleteSession(firstID)
        try expect(provider.account != nil && first.busy)
        let stillSaved = try await sessions.load(id: firstID)
        try expect(stillSaved != nil)

        let order = library.sessionList.map(\.id)
        library.openSession(firstID)
        try expect(library.sidebarSelectionID == firstID && library.current === first && !library.navigating)
        try await wait { !library.navigating }
        try expect(library.current === first && library.draft == "Unsent next request")
        try expect(library.sessionList.map(\.id) == order)
        library.stop()
        try await wait { !first.busy }
        try expect(second.busy && first.messages.last?.status == .interrupted)
        secondProvider.pending?.yield(.text(" — second completed"))
        secondProvider.pending?.yield(.completed)
        secondProvider.pending?.finish()
        try await wait { !second.busy }
        let selected = try await sessions.preferredID(identity: provider.conversationIdentity)
        try expect(selected == firstID && library.currentSessionID == firstID)
        let renamed = try await sessions.load(id: firstID)
        try expect(renamed?.title == "Renamed while running")
        try expect(firstProvider.inputs.count == 1 && secondProvider.inputs.count == 1)
        try expect(!library.isSessionResponding(firstID) && !library.isSessionResponding(secondID))
        first.restore()
        try expect(first.busy && !library.isSessionResponding(firstID))
        await first.waitUntilIdle()

        library.openSession(secondID)
        try await wait { !library.navigating }
        try expect(library.messages.last?.text == "Hello world — second completed")
        library.draft = "Continue second"
        secondProvider.holdOpen = false // Completed conversations now reuse their resident provider.
        library.send()
        try await wait { !library.hasRunningOperations }
        try expect(provider.children.last?.inputs.last?.map(\.text) == ["Second request", "Hello world — second completed", "Continue second"])
    }

    func backgroundApprovalsStayWithTheirConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root.appendingPathComponent("sessions")))
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        library.selectWorkspace(root)
        try await wait { !library.navigating }
        let first = library.current
        let firstID = library.currentSessionID!
        provider.children.last!.scripted = [[.toolCall(ToolCall(id: "a", name: "shell", arguments: #"{"command":"printf A >> effect-a"}"#)), .completed]]
        library.setAutoApproveTools(false)
        library.draft = "First command"
        library.send()
        try await wait { first.tools.pendingApproval != nil }
        let firstApproval = first.tools.pendingApproval!.id
        library.newConversation()
        try await wait { !library.navigating }
        let second = library.current
        provider.children.last!.scripted = [[.toolCall(ToolCall(id: "b", name: "shell", arguments: #"{"command":"printf B >> effect-b"}"#)), .completed]]
        library.setAutoApproveTools(false)
        library.draft = "Second command"
        library.send()
        try await wait { second.tools.pendingApproval != nil }
        library.tools.resolveApproval(id: firstApproval, approved: true)
        try expect(first.tools.pendingApproval != nil && second.tools.pendingApproval != nil)
        library.setAutoApproveTools(true)
        try await wait { !second.busy }
        try expect(try String(contentsOf: root.appendingPathComponent("effect-b"), encoding: .utf8) == "B")
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("effect-a").path))
        library.openSession(firstID)
        try await wait { !library.navigating }
        try expect(!library.autoApproveTools && library.tools.pendingApproval?.id == firstApproval)
        library.stopAll()
        try await wait { !library.hasRunningOperations }
        try expect(first.tools.pendingApproval == nil)
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("effect-a").path))
        library.newConversation()
        try await wait { !library.navigating }
        try expect(library.autoApproveTools)
        let lastProvider = provider.children.last!
        library.draft = "Cancel before starting"
        library.send()
        library.stopAll()
        try await wait { !library.hasRunningOperations }
        try expect(lastProvider.inputs.isEmpty && library.draft == "Cancel before starting")
    }

    func workspaceSelectionDoesNotInterruptRunningConversations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstFolder = root.appendingPathComponent("first")
        let secondFolder = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root.appendingPathComponent("sessions")))
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        library.selectWorkspace(firstFolder)
        try await wait { !library.navigating }
        let running = library.current
        let runner = provider.children.last!
        runner.holdOpen = true
        library.draft = "Keep running"
        library.send()
        try await wait { runner.pending != nil }
        let runningID = library.currentSessionID!
        library.draft = "Keep this draft"

        // A selected workspace is fixed, including while its conversation is running.
        try expect(!library.canSelectWorkspace)
        library.selectWorkspace(secondFolder)
        try expect(library.current === running && !library.navigating)
        try expect(running.workspace?.root.resolvingSymlinksInPath().path == firstFolder.resolvingSymlinksInPath().path)

        library.newConversation()
        try await wait { !library.navigating }
        let fresh = library.current
        let freshID = library.currentSessionID
        try expect(library.workspace?.root == running.workspace?.root)
        try expect(library.canSelectWorkspace && running.busy)
        library.setAutoApproveTools(true)
        try expect(library.autoApproveTools)
        library.draft = "New draft"
        library.selectWorkspace(secondFolder)
        try await wait { !library.navigating }
        try expect(library.current === fresh && library.currentSessionID == freshID)
        try expect(library.draft == "New draft")
        try expect(library.workspace?.root.resolvingSymlinksInPath().path == secondFolder.resolvingSymlinksInPath().path)
        try expect(library.canSelectWorkspace && running.busy && library.autoApproveTools)
        library.send()
        try await wait { !library.navigating && !fresh.busy }
        try expect(!library.canSelectWorkspace && running.busy)
        library.selectWorkspace(firstFolder)
        try expect(!library.navigating)
        try expect(library.workspace?.root.resolvingSymlinksInPath().path == secondFolder.resolvingSymlinksInPath().path)

        library.openSession(runningID)
        try await wait { !library.navigating }
        try expect(library.current === running && library.draft == "Keep this draft")
        runner.pending?.yield(.completed)
        runner.pending?.finish()
        try await wait { !running.busy }
        try expect(running.messages.last?.status == .complete)
        try expect(runner.inputs.count == 1)
    }

    func sevenOpenSessionsSwitchSynchronouslyWithoutRewritingSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        var ids: [UUID] = []
        for index in 0..<7 {
            let messages = [Message(role: .user, text: "Session \(index)"), Message(role: .assistant, text: "Completed reply")]
            ids.append(try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity, selectedModel: "test",
                messages: messages, history: messages, activeTurn: false), id: UUID(), select: false))
        }
        try await sessions.select(ids[0])
        let library = try ChatLibrary(provider: provider, sessions: sessions)
        library.restore()
        try await wait { !library.hasRunningOperations }
        let inodes = try ids.map { try snapshotInode(root, $0) }
        var opened = [library.current]
        for id in ids.dropFirst() {
            library.openSession(id)
            try await wait { !library.hasRunningOperations }
            try expect(library.currentSessionID == id && library.error == nil)
            opened.append(library.current)
        }
        try expect(library.openConversations.count == 7)
        let providerCount = provider.children.count
        for _ in 0..<10 {
            for (index, id) in ids.enumerated() {
                library.openSession(id)
                // No suspension: this must be a selection, not an asynchronous load/save.
                try expect(library.current === opened[index] && !library.navigating)
            }
        }
        try await wait { !library.hasRunningOperations }
        try expect(provider.children.count == providerCount)
        try expect(try ids.map { try snapshotInode(root, $0) } == inodes)
        let selected = try await sessions.preferredID(identity: provider.conversationIdentity)
        try expect(selected == ids.last)

        // Opening two more saved sessions evicts the least recently visited one.
        for index in 0..<2 {
            let messages = [Message(role: .user, text: "Extra \(index)")]
            let extra = try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity,
                selectedModel: "test", messages: messages, history: messages, activeTurn: false), id: UUID(), select: false)
            library.openSession(extra)
            try await wait { !library.hasRunningOperations }
        }
        try expect(library.openConversations.count == 8 && library.sessionList.contains { $0.id == ids[0] })
        try expect(!library.openConversations.contains { $0 === opened[0] })
        library.openSession(ids[0])
        try await wait { !library.hasRunningOperations }
        try expect(library.current !== opened[0] && library.messages == opened[0].messages)
        library.draft = "Keep this draft"

        // Preferences persist where they change, without requiring navigation away.
        library.selectedModel = "another-model"
        try await wait { !library.hasRunningOperations }
        let saved = try await sessions.load(id: ids[0])
        try expect(saved?.selectedModel == "another-model")
        library.selectedModel = "pending-save"
        library.deleteSession(ids[0]) // A pending preference save must not resurrect deleted history.
        try await wait { !library.hasRunningOperations }
        try expect(!library.openConversations.contains { $0.currentSessionID == ids[0] })
        let deleted = try await sessions.load(id: ids[0])
        try expect(deleted == nil)
    }

    func coldSelectionsAreSupersededAndRecoveryRemainsDurable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        let messages = [Message(role: .user, text: "Recover"), Message(role: .assistant, text: "Partial", status: .streaming)]
        let interrupted = try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity, selectedModel: "test",
            messages: messages, history: [], activeTurn: true), id: UUID(), select: false)
        let other = try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity, selectedModel: "test",
            messages: [Message(role: .user, text: "Other")], history: [], activeTurn: false), id: UUID(), select: false)
        let library = try ChatLibrary(provider: provider, sessions: sessions, residentLimit: 1)
        library.restore()
        try await wait { !library.hasRunningOperations }
        let original = library.current
        library.openSession(interrupted)
        library.openSession(other)
        try expect(library.sidebarSelectionID == other && library.current === original)
        try await wait { !library.hasRunningOperations }
        try expect(library.currentSessionID == other)

        library.openSession(interrupted)
        library.openSession(other) // Return to a resident tab before the cold load finishes.
        try expect(library.currentSessionID == other && !library.navigating)
        try await Task.sleep(for: .milliseconds(10))
        try expect(library.currentSessionID == other && library.error == nil)

        library.openSession(interrupted)
        try await wait { !library.hasRunningOperations }
        try expect(library.currentSessionID == interrupted && library.messages.last?.status == .interrupted)
        let recovered = try await sessions.load(id: interrupted)
        try expect(recovered?.activeTurn == false && recovered?.messages.last?.status == .interrupted)
        try expect(provider.children.allSatisfy { $0.inputs.isEmpty })

        library.openSession(other)
        try await wait { !library.hasRunningOperations }
        try expect(!library.openConversations.contains { $0.currentSessionID == interrupted })
        try Data("not JSON".utf8).write(to: root.appendingPathComponent("\(interrupted).json"))
        library.openSession(interrupted)
        try await wait { !library.hasRunningOperations }
        try expect(library.currentSessionID == other && library.error != nil)
        library.openSession(other)
        try expect(library.error == nil && !library.navigating)
    }

    func residentLimitProtectsRunningWorkAndDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root), residentLimit: 1)
        library.restore(); try await wait { !library.hasRunningOperations }
        let first = library.current
        let runner = provider.children.last!
        runner.holdOpen = true
        library.draft = "First"; library.send()
        try await wait { runner.pending != nil }
        library.draft = "Keep this draft"
        library.newConversation()
        try await wait { !library.navigating }
        try expect(library.openConversations.contains { $0 === first })
        runner.pending?.yield(.completed); runner.pending?.finish()
        try await wait { !first.busy }
        try expect(library.openConversations.contains { $0 === first })
        try expect(first.draft == "Keep this draft")
        first.draft = ""
        library.newConversation()
        try expect(!library.openConversations.contains { $0 === first })
        try expect(library.sessionList.contains { $0.id == first.currentSessionID })
        library.stopAll(); try await wait { !library.hasRunningOperations }
    }

    func streamingDoesNotInvalidateSidebarSummaries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root))
        library.restore()
        try await wait { !library.hasRunningOperations }
        let running = library.current
        let runner = provider.children.last!
        runner.holdOpen = true
        library.draft = "Keep the title stable"
        library.send()
        try await wait { runner.pending != nil && running.messages.last?.text.isEmpty == false }
        library.newConversation()
        try await wait { !library.navigating && !library.current.isSaving }
        let flag = ChangeFlag()
        withObservationTracking {
            _ = library.sessionList
        } onChange: {
            Task { @MainActor in flag.changed = true }
        }
        try await Task.sleep(for: .milliseconds(60))
        runner.pending?.yield(.text(" — background update"))
        try await wait { running.messages.last?.text.hasSuffix("background update") == true }
        await Task.yield()
        try expect(!flag.changed)
        library.stopAll()
        try await wait { !library.hasRunningOperations }
    }

    @MainActor private final class ChangeFlag { var changed = false }

    private func snapshotInode(_ directory: URL, _ id: UUID) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("\(id).json").path)
        return (attributes[.systemFileNumber] as! NSNumber).uint64Value
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Conversation operation did not settle")
    }
}
