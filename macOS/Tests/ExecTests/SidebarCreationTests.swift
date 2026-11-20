import AppKit
import Foundation
import SwiftUI

@MainActor private struct ForkFocusHost: View {
    let library: ChatLibrary
    let windows: SessionWindows

    var body: some View {
        ChatWindowLayout(initiallyShowsSidebar: false, sidebarRevealRequest: windows.sidebarRevealRequest) {
            SessionSidebar(store: library, open: windows.openSession, delete: { windows.requestSessionDeletion($0.id) })
        } detail: {
            ChatView(store: library, windows: windows)
        }
    }
}

/// Holds only explicit creation requests; all other traffic stays in the fake transport.
private actor SidebarCreationTransport: AgentTransport {
    nonisolated let responses = FakeAgentTransport()
    private var catalog: [AgentJSON] = []
    private var pending: CheckedContinuation<Data, Error>?
    private(set) var creationRequests = 0
    var creationPending: Bool { pending != nil }

    func setCatalog(_ snapshots: [AgentJSON]) async throws {
        catalog = snapshots
        try await responses.reply("/v1/conversations", .array(snapshots))
        for snapshot in snapshots {
            try await responses.reply(AgentAPI.path(snapshot.decoded(AgentSnapshot.self).id), snapshot)
        }
    }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        if method == "POST", path == "/v1/conversations" || path.hasSuffix("/fork") {
            creationRequests += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        if method == "DELETE" {
            var remaining: [AgentJSON] = []
            for snapshot in catalog {
                let snapshotPath = try await AgentAPI.path(snapshot.decoded(AgentSnapshot.self).id)
                if snapshotPath != path { remaining.append(snapshot) }
            }
            try await setCatalog(remaining)
            return Data("{}".utf8)
        }
        return try await responses.request(method, path, body: body)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        responses.events(method, path, body: body)
    }
    func finishCreation(_ snapshot: AgentJSON) async throws {
        guard let pending else { throw CheckFailure(description: "No pending sidebar creation") }
        let data = try JSONEncoder().encode(snapshot)
        try await setCatalog(catalog + [snapshot])
        self.pending = nil
        pending.resume(returning: data)
    }
    func failCreation() {
        pending?.resume(throwing: ExecError("Synthetic creation failure"))
        pending = nil
    }
}

@MainActor private final class SidebarCreationFixture {
    let transport = SidebarCreationTransport()
    let suite = "exec-sidebar-creation-\(UUID())"
    let preferences: UserDefaults
    let library: ChatLibrary
    let windows: SessionWindows
    let workspace: URL
    let roots: [AgentJSON]
    let child: AgentJSON?

    init(topLevelCount: Int = 1, selected: Bool = true) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exec-sidebar-\(UUID())")
        workspace = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(try JSONEncoder().encode([ChatModel(id: "deepseek/test", name: "Test")]), forKey: "chat.modelCatalog")
        let initial = (0..<topLevelCount).map { _ in Self.snapshot(workspace: directory) }
        roots = initial
        child = initial.first.map { Self.snapshot(workspace: directory, parent: $0["id"]) }
        library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        windows = SessionWindows(library: library)
        let config = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration()))
        try await transport.responses.reply("/v1/library", config)
        try await transport.setCatalog(roots + (child.map { [$0] } ?? []))
        if selected {
            if let first = roots.first { try library.current.apply(first.decoded(AgentSnapshot.self)) }
            else { try library.current.setInitialWorkspace(Workspace(root: workspace)) }
        }
        try await library.refreshSharedState()
    }
    static func snapshot(workspace: URL, parent: AgentJSON = .null) -> AgentJSON {
        var metadata: [String: AgentJSON] = ["title": .string("Test session"), "manuallyNamed": .bool(false), "activityAt": .number(1000)]
        if parent.string != nil {
            metadata["parent"] = .object(["sessionId": parent, "operationId": .string(UUID().uuidString), "toolCallId": .string("delegate")])
        }
        return .object([
            "id": .string(UUID().uuidString), "model": .string("deepseek/test"), "workspace": .string(workspace.path),
            "configuration": .object(["settings": .object(["systemPrompt": .string(""), "autoApprove": .bool(true)]),
                "instructionsFrozen": .bool(true), "workspaceInstructions": .null]),
            "metadata": .object(metadata), "messages": .array([]), "pendingInput": .array([]),
            "operation": .null, "approval": .null, "activeToolCallID": .null, "storageError": .null])
    }
    func waitForCreation() async throws {
        for _ in 0..<200 {
            if await transport.creationPending { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out awaiting sidebar creation")
    }
    func finishCreation() async throws {
        try await transport.finishCreation(Self.snapshot(workspace: workspace))
    }
    func close() {
        library.closePresentations()
        Task { await transport.failCreation() }
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: workspace)
    }
}

@MainActor struct SidebarCreationTests {
    func pickerKeepsCurrentUntilCreationCompletes() async throws {
        for succeeds in [true, false] {
            let fixture = try await SidebarCreationFixture()
            defer { fixture.close() }
            let library = fixture.library, windows = fixture.windows
            let original = library.current
            original.draft = "Keep my draft"
            let window = NSWindow()
            var completion: (@MainActor (URL?) -> Void)?
            var pickerCount = 0
            var pickerOwner: NSWindow?
            let panel = ChatPanel(library: library, conversation: original) { owner, _, callback in
                pickerOwner = owner
                pickerCount += 1
                completion = callback
            }
            panel.window = window
            windows.newConversation()
            let pending = library.pendingNewConversation!
            panel.chooseInitialWorkspaceIfNeeded()
            windows.newConversation()
            panel.chooseInitialWorkspaceIfNeeded()
            try expect(pickerCount == 1 && pickerOwner === window && library.pendingNewConversation === pending)
            try expect(library.current === original && library.hasConversation(original))
            try expect(library.sidebarSelectionID == original.currentSessionID)
            completion?(fixture.workspace)
            try await fixture.waitForCreation()
            try expect(library.current === original && original.draft == "Keep my draft")
            try expect(library.sidebarSelectionID == original.currentSessionID && windows.sidebarRevealRequest == 0)
            if succeeds { try await fixture.finishCreation() }
            else { await fixture.transport.failCreation() }
            await library.waitForNavigation()
            try expect(original.draft == "Keep my draft")
            if succeeds {
                try expect(library.current === pending && pending.currentSessionID != nil)
                try expect(library.sidebarSelectionID == pending.currentSessionID && windows.sidebarRevealRequest == 1)
            } else {
                try expect(library.current === original && library.error != nil)
                try expect(library.sidebarSelectionID == original.currentSessionID && windows.sidebarRevealRequest == 0)
                library.error = nil
                windows.newConversation()
                try expect(library.current === original && library.pendingNewConversation !== pending)
                try expect(library.pendingNewConversation?.needsInitialWorkspaceSelection == true)
            }
            let requests = await fixture.transport.creationRequests
            try expect(requests == 1)
        }
    }

    func onlySecondTopLevelCreationRevealsAfterSuccess() async throws {
        for count in 0...2 {
            let fixture = try await SidebarCreationFixture(topLevelCount: count)
            defer { fixture.close() }
            let library = fixture.library, windows = fixture.windows
            windows.newConversation()
            let creating = library.pendingNewConversation ?? library.current
            try expect(windows.sidebarRevealRequest == 0 && creating.currentSessionID == nil)
            try expect(creating.workspace == nil && creating.needsInitialWorkspaceSelection)
            try creating.setInitialWorkspace(Workspace(root: fixture.workspace))
            creating.scheduleSave()
            try await fixture.waitForCreation()
            try expect(windows.sidebarRevealRequest == 0)
            try await fixture.finishCreation()
            await creating.waitForPendingSave()
            try expect(creating.error == nil && creating.currentSessionID != nil)
            try expect(windows.sidebarRevealRequest == (count == 1 ? 1 : 0))
            // Further saves/checkpoints must not repeat the one-shot event.
            try await creating.saveIfIdle(force: true)
            try await library.refreshSharedState()
            try expect(windows.sidebarRevealRequest == (count == 1 ? 1 : 0))
        }
    }

    func blankWorkspaceCreationRevealsOnlyAfterSelectionAndSave() async throws {
        let fixture = try await SidebarCreationFixture(selected: false)
        defer { fixture.close() }
        let library = fixture.library, windows = fixture.windows
        windows.newConversation()
        let blank = library.pendingNewConversation!
        await blank.waitForPendingSave()
        try expect(blank.workspace == nil && blank.needsInitialWorkspaceSelection)
        try expect(windows.sidebarRevealRequest == 0)
        let requests = await fixture.transport.creationRequests
        try expect(requests == 0)
        library.selectWorkspace(fixture.workspace)
        try await fixture.waitForCreation()
        try expect(windows.sidebarRevealRequest == 0)
        try await fixture.finishCreation()
        await library.waitForNavigation()
        try expect(library.error == nil && blank.currentSessionID != nil)
        try expect(windows.sidebarRevealRequest == 1)
        try await blank.didCheckpoint?()
        try expect(windows.sidebarRevealRequest == 1)
    }

    func failedCreationAndForkNeverReveal() async throws {
        for fork in [false, true] {
            let fixture = try await SidebarCreationFixture()
            defer { fixture.close() }
            let library = fixture.library, windows = fixture.windows
            let source = library.current
            if fork { windows.forkConversation(source) }
            else { windows.newConversation() }
            let creating = library.pendingNewConversation ?? library.current
            if !fork {
                try creating.setInitialWorkspace(Workspace(root: fixture.workspace))
                creating.scheduleSave()
            }
            try await fixture.waitForCreation()
            try expect(windows.sidebarRevealRequest == 0)
            await fixture.transport.failCreation()
            await creating.waitForPendingSave()
            await library.waitForNavigation()
            try expect(library.error != nil && windows.sidebarRevealRequest == 0)
            try await library.refreshSharedState()
            try expect(windows.sidebarRevealRequest == 0)
            let requests = await fixture.transport.creationRequests
            try expect(requests == 1)
        }
    }

    func forkRevealsOnlyForSecondTopLevelSession() async throws {
        for count in 1...2 {
            let fixture = try await SidebarCreationFixture(topLevelCount: count)
            defer { fixture.close() }
            let library = fixture.library, windows = fixture.windows
            windows.forkConversation(library.current)
            try await fixture.waitForCreation()
            // Navigation is blocked during a fork; rejected commands are not creation.
            windows.newConversation()
            windows.forkConversation(library.current)
            try expect(windows.sidebarRevealRequest == 0)
            try await fixture.finishCreation()
            await library.waitForNavigation()
            try expect(library.error == nil && windows.composerFocusRequest == 1)
            try expect(windows.sidebarRevealRequest == (count == 1 ? 1 : 0))
            let requests = await fixture.transport.creationRequests
            try expect(requests == 1)
        }
    }

    /// Uses the running NSApplication loop in --composer-events. Direct insertText
    /// calls can succeed even when the editor cannot receive real keyboard input.
    func forkFocusesMountedComposerAfterNavigation() async throws {
        for count in 1...2 {
            let fixture = try await SidebarCreationFixture(topLevelCount: count)
            defer { fixture.close() }
            let library = fixture.library, windows = fixture.windows
            let host = NSHostingView(rootView: ForkFocusHost(library: library, windows: windows))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            windows.mainWindow = window
            // An entirely offscreen window may not activate on current macOS.
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            defer { window.orderOut(nil); window.contentView = nil }
            func editor(in root: NSView) -> ComposerTextInput.EditorScrollView? {
                if let view = root as? ComposerTextInput.EditorScrollView { return view }
                return root.subviews.lazy.compactMap { editor(in: $0) }.first
            }
            func settle() async throws {
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
            }
            func requireActiveWindow() async throws {
                guard !NSApp.isActive || !window.isKeyWindow else { return }
                // Synthetic events bypass the Window Server's activation click.
                // Restore the fixture window, never the editor's responder.
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                for _ in 0..<100 {
                    if NSApp.isActive && window.isKeyWindow { return }
                    try await Task.sleep(for: .milliseconds(20))
                }
                throw CheckFailure(description: "Fork fixture did not acquire its active key window")
            }
            func postKey(_ character: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) {
                for eventType in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = NSEvent.keyEvent(with: eventType, location: .zero, modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: character, charactersIgnoringModifiers: character,
                        isARepeat: false, keyCode: keyCode)!
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try await settle()
            try await requireActiveWindow()
            guard let original = editor(in: host) else { throw CheckFailure(description: "Source composer not mounted") }
            try expect(window.makeFirstResponder(original.editor))
            try await settle()
            let source = library.current
            for (character, keyCode) in [("/", UInt16(44)), ("f", 3), ("o", 31), ("r", 15), ("k", 40)] {
                postKey(character, keyCode: keyCode)
            }
            try await settle()
            guard source.draft == "/fork" else {
                throw CheckFailure(description: "Source typing failed: draft=\(source.draft.debugDescription), text=\(original.editor.string.debugDescription), active=\(NSApp.isActive), key=\(window.isKeyWindow), responder=\(String(describing: window.firstResponder)), editable=\(original.editor.isEditable), selection=\(original.editor.selectedRange())")
            }
            postKey("\r", keyCode: 36)
            try await fixture.waitForCreation()
            // Cover a fast replacement and a disabled source that has settled.
            if count == 2 { try await settle() }
            try await fixture.finishCreation()
            await library.waitForNavigation()
            // Exercise input during reveal/layout, not only after a 600ms grace period.
            try await settle()
            guard let fork = editor(in: host) else { throw CheckFailure(description: "Fork composer not mounted") }
            try expect(library.current !== source && library.error == nil)
            try expect(fork !== original && fork.editor.isEditable && fork.editor.isSelectable)
            try await requireActiveWindow()
            try expect(window.firstResponder === fork.editor)
            guard fork.editor.shouldDrawInsertionPoint,
                  fork.editor.visibleRect.height > 0,
                  fork.editor.selectedRange() == NSRange(location: 0, length: 0) else {
                throw CheckFailure(description: "Fork caret unavailable: draws=\(fork.editor.shouldDrawInsertionPoint), frame=\(fork.editor.frame), visible=\(fork.editor.visibleRect), selection=\(fork.editor.selectedRange())")
            }
            postKey("a", keyCode: 0)
            try await settle()
            try expect(library.current.draft == "a")
            // Clicking the newly opened editor must also leave it usable.
            let point = fork.editor.convert(NSPoint(x: 30, y: 8), to: nil)
            try expect(window.contentView?.hitTest(point) === fork.editor)
            for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: eventType, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: -1, clickCount: 1, pressure: eventType == .leftMouseDown ? 1 : 0)!
                NSApp.postEvent(event, atStart: false)
            }
            try await settle()
            postKey("b", keyCode: 11)
            try await settle()
            try expect(library.current.draft == "ab")
            // Shift-arrow selection is handled by NSTextView, independent of
            // the application's Edit menu (the fixture has no main menu).
            postKey("\u{f702}", keyCode: 123, flags: [.shift])
            postKey("\u{f702}", keyCode: 123, flags: [.shift])
            try await settle()
            guard fork.editor.selectedRange() == NSRange(location: 0, length: 2) else {
                throw CheckFailure(description: "Fork keyboard selection failed: text=\(fork.editor.string.debugDescription), selection=\(fork.editor.selectedRange()), responder=\(String(describing: window.firstResponder))")
            }
            postKey("r", keyCode: 15)
            try await settle()
            try expect(library.current.draft == "r" && fork.editor.selectedRange() == NSRange(location: 1, length: 0))
            postKey("\u{f702}", keyCode: 123, flags: [.shift])
            try await settle()
            try expect(fork.editor.selectedRange() == NSRange(location: 0, length: 1))
            postKey("x", keyCode: 7)
            try await settle()
            try expect(library.current.draft == "x" && source.draft.isEmpty)
        }
    }

    func navigationDeletionAndCatalogChangesNeverReveal() async throws {
        let fixture = try await SidebarCreationFixture()
        defer { fixture.close() }
        let library = fixture.library, windows = fixture.windows
        let rootID = try fixture.roots[0].decoded(AgentSnapshot.self).id
        let childID = try fixture.child!.decoded(AgentSnapshot.self).id
        windows.openSession(childID)
        await library.waitForNavigation()
        try expect(library.currentSessionID == childID && windows.sidebarRevealRequest == 0)
        let other = SidebarCreationFixture.snapshot(workspace: fixture.workspace)
        let otherID = try other.decoded(AgentSnapshot.self).id
        try await fixture.transport.setCatalog(fixture.roots + [fixture.child!, other])
        try await library.refreshSharedState()
        try expect(library.sessionList.filter { $0.parent == nil }.count == 2)
        try expect(windows.sidebarRevealRequest == 0)
        windows.openSession(otherID)
        await library.waitForNavigation()
        library.deleteSession(otherID)
        await library.waitForNavigation()
        try expect(!library.sessionList.contains { $0.id == otherID })
        windows.openSession(rootID)
        await library.waitForNavigation()
        library.deleteSession(childID)
        await library.waitForNavigation()
        try expect(library.sessionList.count == 1 && windows.sidebarRevealRequest == 0)
    }

    func interveningCatalogChangesDoNotMasqueradeAsSecondCreation() async throws {
        for replaceOriginal in [false, true] {
            let fixture = try await SidebarCreationFixture()
            defer { fixture.close() }
            let library = fixture.library, windows = fixture.windows
            windows.newConversation()
            let creating = library.pendingNewConversation ?? library.current
            try creating.setInitialWorkspace(Workspace(root: fixture.workspace))
            creating.scheduleSave()
            try await fixture.waitForCreation()
            let other = SidebarCreationFixture.snapshot(workspace: fixture.workspace)
            try await fixture.transport.setCatalog(replaceOriginal ? [other] : fixture.roots + [fixture.child!, other])
            try await library.refreshSharedState()
            try expect(windows.sidebarRevealRequest == 0)
            try await fixture.finishCreation()
            await creating.waitForPendingSave()
            try expect(creating.error == nil && creating.currentSessionID != nil)
            try expect(windows.sidebarRevealRequest == 0)
        }
    }
}
