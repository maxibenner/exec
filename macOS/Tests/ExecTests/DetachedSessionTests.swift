import AppKit
import SwiftUI

@MainActor struct DetachedSessionTests {
    func movingRunningConversationsPreservesOwnershipAndControls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: sessions, residentLimit: 1)
        defer { library.stopAll() }
        let startupPanel = ChatPanel(library: library, conversation: library.current)
        library.restore()
        try expect(library.authenticating && startupPanel.busy && !startupPanel.canEditDraft)
        try expect(!startupPanel.isWorking && !library.isWorking)
        try await wait { !library.hasRunningOperations }
        try expect(!startupPanel.isWorking && !library.isWorking)
        let conversation = library.current
        let transport = provider.children.last!
        transport.holdOpen = true
        library.draft = "Keep this turn running"
        library.send()
        try await wait { transport.pending != nil }
        try expect(startupPanel.isWorking && library.isWorking)
        let id = conversation.currentSessionID!
        conversation.draft = "Unsent follow-up"
        let tools = conversation.tools
        var presented: ChatStore?
        library.detachSession(id) { presented = $0 }
        try expect(presented === conversation && library.current !== conversation)
        try expect(library.detachedSessionIDs == [id] && conversation.busy)
        try expect(!library.sidebarSessions.contains { $0.id == id })
        try expect(library.sessionList.contains { $0.id == id })
        try expect(conversation.tools === tools && conversation.draft == "Unsent follow-up")
        try expect(transport.inputs.count == 1)
        let main = library.current
        main.draft = "Main window draft"
        let panel = ChatPanel(library: library, conversation: conversation)
        panel.draft = "Detached draft"
        try expect(main.draft == "Main window draft" && conversation.draft == "Detached draft")
        library.openSession(id) // Main-window navigation must not mount a second editor.
        try expect(library.current === main)
        var presentedTwice = false
        library.detachSession(id) { _ in presentedTwice = true }
        try expect(!presentedTwice)
        panel.stop()
        try await wait { !conversation.busy }
        try expect(conversation.messages.last?.status == .interrupted && main.draft == "Main window draft")
        transport.holdOpen = false
        panel.draft = "Detached follow-up"
        panel.send()
        try await wait { !library.hasRunningOperations }
        try expect(library.current === main && transport.inputs.count == 2)
        try expect(conversation.messages.last?.status == .complete)
        // Pin even idle, fully saved detached sessions beyond the resident limit.
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        try expect(library.openConversations.contains { $0 === conversation })
        library.attachSession(id)
        try expect(library.current === conversation && library.detachedSessionIDs.isEmpty)
        try expect(library.sidebarSessions.contains { $0.id == id })
        try expect(conversation.tools === tools && transport.inputs.count == 2)
        library.attachSession(id) // Repeated closes are harmless.
        try expect(library.current === conversation)
    }

    func detachingAllWorkspaceSessionsShowsPlaceholder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
        let library = try ChatLibrary(provider: provider, sessions: sessions)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        library.selectWorkspace(root)
        try await wait { !library.hasRunningOperations }
        let first = library.current
        let workspaceRoot = first.workspace?.root
        try expect(workspaceRoot != nil)
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        let second = library.current
        let ids = Set(library.sidebarSessions.map(\.id))
        try expect(ids.count == 2)

        var presented: ChatStore?
        library.detachSession(second.currentSessionID!) { presented = $0 }
        try await wait { !library.hasRunningOperations }
        try expect(presented === second && library.current === first && library.sidebarSessions.count == 1)
        library.detachSession(first.currentSessionID!) { _ in }
        try await wait { !library.hasRunningOperations }
        let panel = ChatPanel(library: library, conversation: library.current)
        try expect(library.sidebarSessions.isEmpty && library.detachedSessionIDs == ids)
        try expect(!panel.hasConversation && library.workspace == nil)
        try expect(!library.current.needsInitialWorkspaceSelection)
        try expect(Set(library.sessionList.map(\.id)) == ids)
        let saved = try await sessions.list(identity: provider.conversationIdentity)
        try expect(Set(saved.map(\.id)) == ids)
        try expect(first.workspace?.root == workspaceRoot && second.workspace?.root == workspaceRoot)

        // Explicit creation from the placeholder still uses the normal workspace picker.
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        try expect(library.current.needsInitialWorkspaceSelection && library.sidebarSessions.isEmpty)
        library.attachSession(first.currentSessionID!)
        try expect(library.current === first && library.hasConversation(first))
        try expect(library.sidebarSessions.map(\.id) == [first.currentSessionID!])
    }

    func coldDetachAndNativeClosePreserveState() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        let coldID = UUID()
        let messages = [Message(role: .user, text: "A saved conversation")]
        try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity, selectedModel: "test",
            messages: messages, history: messages, activeTurn: false), id: coldID)
        let library = try ChatLibrary(provider: provider, sessions: sessions, residentLimit: 1)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        library.newConversation()
        try await wait { !library.hasRunningOperations }
        let main = library.current
        try expect(!library.openConversations.contains { $0.currentSessionID == coldID })
        let windows = SessionWindows(library: library)
        windows.detach(coldID)
        try await wait { !library.navigating && library.detachedSessionIDs.contains(coldID) }
        guard let detached = library.openConversations.first(where: { $0.currentSessionID == coldID }) else {
            throw CheckFailure(description: "Detached conversation was not retained")
        }
        defer { windows.attach(coldID) }
        try expect(library.current === main)
        let state = windows.presentation(for: detached)
        state.followsLatest = false
        state.expanded[messages[0].id] = true
        detached.draft = "Keep my detached draft"
        let count = provider.children.count
        windows.detach(coldID) // Focus the same window, never load a second provider.
        try expect(provider.children.count == count)
        try expect(windows.presentation(for: detached) === state)
        // Exercise the actual NSWindow close delegate, not just library attachment.
        let native = NSApp.windows.first { $0.title == "A saved conversation" }
        try expect(native != nil)
        try expect(native?.titleVisibility == .visible)
        try expect(native?.toolbar == nil)
        native?.performClose(nil)
        try expect(library.detachedSessionIDs.isEmpty && library.current === detached)
        try expect(detached.draft == "Keep my detached draft")
        try expect(windows.presentation(for: detached) === state && state.expanded[messages[0].id] == true)
        let stored = try await sessions.load(id: coldID)
        try expect(stored?.messages.map(\.text) == messages.map(\.text))
        windows.detach(coldID)
        try expect(windows.presentation(for: detached) === state)
        library.disconnect()
        try await wait { !library.hasRunningOperations }
        windows.closeInvalidWindows()
        try expect(library.detachedSessionIDs.isEmpty && native?.isVisible != true)
        try expect(!library.openConversations.contains { $0 === detached })
    }

    func sidebarReorderingPreservesDetachedConversations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let sessions = SessionStore(directory: root)
        for index in 1...4 {
            let messages = [Message(role: .user, text: "Sidebar session \(index)")]
            try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity, selectedModel: "test",
                messages: messages, history: messages, activeTurn: false), id: UUID())
        }
        let library = try ChatLibrary(provider: provider, sessions: sessions)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        let order = library.sidebarSessions.map(\.id)
        var detached: ChatStore?
        library.detachSession(order[1]) { detached = $0 }
        try await wait { !library.hasRunningOperations }
        detached?.draft = "Detached draft"
        let selected = library.sidebarSelectionID
        try expect(library.sidebarSessions.map(\.id) == [order[0], order[2], order[3]])

        // Visible row 1 is the third stored session, not the detached session.
        library.moveSidebarSessions(from: [1], to: 0)
        try await wait { !library.hasRunningOperations }
        try expect(library.sidebarSessions.map(\.id) == [order[2], order[0], order[3]])
        try expect(library.detachedSessionIDs == [order[1]] && detached?.draft == "Detached draft")
        try expect(library.sidebarSelectionID == selected)
        library.moveSidebarSessions(from: [0, 1], to: 3)
        try await wait { !library.hasRunningOperations }
        try expect(library.sidebarSessions.map(\.id) == [order[3], order[2], order[0]])
        try expect(library.sessionShortcuts.map { $0.session.id } == library.sidebarSessions.map(\.id))
        let beforeInvalid = library.sessionList.map(\.id)
        library.moveSidebarSessions(from: [3], to: 0)
        library.moveSidebarSessions(from: [0], to: 4)
        try expect(!library.navigating && library.sessionList.map(\.id) == beforeInvalid)
        let persisted = try await sessions.list(identity: provider.conversationIdentity)
        try expect(persisted.map(\.id) == beforeInvalid)
        library.attachSession(order[1])
        try expect(library.current === detached && library.current.draft == "Detached draft")
        try expect(library.sidebarSessions.map(\.id) == beforeInvalid)
    }

    func pendingApprovalsMoveWithoutExecutionOrReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let library = try ChatLibrary(provider: provider, sessions: SessionStore(directory: root.appendingPathComponent("sessions")))
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        library.selectWorkspace(root)
        try await wait { !library.hasRunningOperations }
        let conversation = library.current
        provider.children.last!.scripted = [[.toolCall(ToolCall(id: "pending", name: "shell",
            arguments: #"{"command":"touch must-not-exist"}"#)), .completed]]
        library.setAutoApproveTools(false)
        library.draft = "Ask before executing"
        library.send()
        try await wait { conversation.tools.pendingApproval != nil || (!library.navigating && !conversation.busy) }
        guard let approval = conversation.tools.pendingApproval?.id else {
            throw CheckFailure(description: "Expected pending approval; error: \(conversation.error ?? "none"), messages: \(conversation.messages.map(\.text))")
        }
        let id = conversation.currentSessionID!
        var moved: ChatStore?
        library.detachSession(id) { moved = $0 }
        try expect(moved === conversation)
        try expect(conversation.tools.pendingApproval?.id == approval && library.current !== conversation)
        library.attachSession(id)
        try expect(library.tools.pendingApproval?.id == approval)
        library.tools.resolveApproval(id: approval, approved: false)
        try await wait { !library.hasRunningOperations }
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-exist").path))
        try expect(conversation.messages.filter { $0.toolResult?.call.id == "pending" }.count == 1)
    }

    private func wait(file: String = #fileID, line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "\(file):\(line): Detached session operation did not settle")
    }
}
