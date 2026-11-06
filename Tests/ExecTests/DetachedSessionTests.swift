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
        library.restore()
        try await wait { !library.hasRunningOperations }
        let conversation = library.current
        let transport = provider.children.last!
        transport.holdOpen = true
        library.draft = "Keep this turn running"
        library.send()
        try await wait { transport.pending != nil }
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

    func dragCancellationAndForeignPayloadsAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ChatLibrary(provider: FakeProvider(), sessions: SessionStore(directory: root))
        let windows = SessionWindows(library: library)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let unknown = UUID()
        pasteboard.writeObjects([SessionDrag.item(for: unknown)])
        try expect(SessionDrag.session(in: pasteboard, windows: windows) == nil)
        windows.draggingSessionID = unknown
        try expect(SessionDrag.session(in: pasteboard, windows: windows) == nil)
        let frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let outside = NSPoint(x: 800, y: 600)
        try expect(SessionDrag.shouldDetach(operation: [], point: outside, sourceFrame: frame, mouseReleased: true, cancelled: false))
        try expect(!SessionDrag.shouldDetach(operation: .move, point: outside, sourceFrame: frame, mouseReleased: true, cancelled: false))
        try expect(!SessionDrag.shouldDetach(operation: [], point: .zero, sourceFrame: frame, mouseReleased: true, cancelled: false))
        try expect(!SessionDrag.shouldDetach(operation: [], point: outside, sourceFrame: frame, mouseReleased: false, cancelled: false))
        try expect(!SessionDrag.shouldDetach(operation: [], point: outside, sourceFrame: frame, mouseReleased: true, cancelled: true))
    }

    func nativeSidebarSelectionDeletionAndReattachment() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let sessions = SessionStore(directory: root)
        for index in 1...3 {
            let messages = [Message(role: .user, text: "Sidebar session \(index)")]
            try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity, selectedModel: "test",
                messages: messages, history: messages, activeTurn: false), id: UUID())
        }
        let library = try ChatLibrary(provider: provider, sessions: sessions)
        defer { library.stopAll() }
        library.restore()
        try await wait { !library.hasRunningOperations }
        let windows = SessionWindows(library: library)
        var deleted: UUID?
        let host = NSHostingView(rootView: SessionSidebar(store: library, windows: windows,
            open: { library.openSession($0) }, delete: { deleted = $0.id }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable($0) }.first
        }
        guard let table = findTable(host) else { throw CheckFailure(description: "Missing native session table") }
        let order = library.sidebarSessions.map(\.id)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await wait { !library.navigating }
        window.makeFirstResponder(table)
        let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{f701}",
            charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125)!
        table.keyDown(with: down)
        try await wait { !library.navigating }
        try expect(table.selectedRow == 1 && library.sidebarSelectionID == order[1])
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{7f}",
            charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        table.keyDown(with: delete)
        try expect(deleted == order[1])
        try checkRoundedDragPreview(table)
        let presentation = windows.presentation(for: library.current)
        presentation.expanded[UUID()] = true
        windows.detach(order[1])
        defer { windows.attach(order[1]) }
        try expect(!library.sessionShortcuts.contains { $0.session.id == order[1] })
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([SessionDrag.item(for: order[1])])
        try expect(SessionDrag.session(in: pasteboard, windows: windows) == nil)
        windows.draggingSessionID = order[1]
        try expect(SessionDrag.session(in: pasteboard, windows: windows) == order[1])
        windows.attach(order[1], before: order[0], reorder: true)
        try await wait { !library.hasRunningOperations }
        try expect(library.sidebarSessions.map(\.id) == [order[1], order[0], order[2]])
        try expect(windows.presentation(for: library.current) === presentation)
        let persisted = try await sessions.list(identity: provider.conversationIdentity)
        try expect(persisted.map(\.id) == library.sidebarSessions.map(\.id))
    }

    private func checkRoundedDragPreview(_ table: NSTableView) throws {
        guard let table = table as? SessionTable.SidebarTable,
              let row = table.rowView(atRow: table.selectedRow, makeIfNecessary: true) else {
            throw CheckFailure(description: "Missing selected sidebar row")
        }
        let appearance = table.appearance
        defer { table.appearance = appearance }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            table.appearance = NSAppearance(named: name)
            guard let preview = table.dragPreview(for: table.selectedRow),
                  let data = preview.image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data) else {
                throw CheckFailure(description: "Missing sidebar drag preview")
            }
            try expect(preview.frame == table.convert(row.bounds, from: row))
            try expect(preview.image.size == row.bounds.size)
            // The empty right side must carry a solid container, not just text;
            // transparent corners distinguish the rounded card from a rectangle.
            let right = bitmap.pixelsWide - 2
            try expect((bitmap.colorAt(x: right, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.95)
            try expect((bitmap.colorAt(x: bitmap.pixelsWide - 1, y: 0)?.alphaComponent ?? 1) < 0.05)
        }
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
