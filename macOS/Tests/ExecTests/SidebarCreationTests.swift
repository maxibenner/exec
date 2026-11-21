import AppKit
import Foundation
import SwiftUI

@MainActor private struct ForkFocusHost: View {
    let library: ChatLibrary
    let windows: SessionWindows
    var initiallyShowsSidebar = false

    var body: some View {
        ChatWindowLayout(initiallyShowsSidebar: initiallyShowsSidebar, sidebarRevealRequest: windows.sidebarRevealRequest) {
            SessionSidebar(store: library, open: windows.openSession, delete: { windows.requestSessionDeletion($0.id) })
        } detail: {
            ChatView(store: library, windows: windows)
        }
    }
}

/// Holds only explicit creation requests; all other traffic stays in the fake transport.
actor SidebarCreationTransport: AgentTransport {
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

// Shared by the ordinary checks and the actual SwiftUI Window scene probe.
@MainActor final class SidebarCreationFixture {
    let transport = SidebarCreationTransport()
    let suite = "exec-sidebar-creation-\(UUID())"
    let preferences: UserDefaults
    let library: ChatLibrary
    let windows: SessionWindows
    let workspace: URL
    let roots: [AgentJSON]
    let child: AgentJSON?

    init(topLevelCount: Int = 1, selected: Bool = true, messages: [AgentJSON] = []) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("exec-sidebar-\(UUID())")
        workspace = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(try JSONEncoder().encode([ChatModel(id: "deepseek/test", name: "Test")]), forKey: "chat.modelCatalog")
        let initial = (0..<topLevelCount).map { _ in Self.snapshot(workspace: directory, messages: messages) }
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
    static func snapshot(workspace: URL, parent: AgentJSON = .null, messages: [AgentJSON] = []) -> AgentJSON {
        var metadata: [String: AgentJSON] = ["title": .string("Test session"), "manuallyNamed": .bool(false), "activityAt": .number(1000)]
        if parent.string != nil {
            metadata["parent"] = .object(["sessionId": parent, "operationId": .string(UUID().uuidString), "toolCallId": .string("delegate")])
        }
        return .object([
            "id": .string(UUID().uuidString), "model": .string("deepseek/test"), "workspace": .string(workspace.path),
            "configuration": .object(["settings": .object(["systemPrompt": .string(""), "autoApprove": .bool(true)]),
                "instructionsFrozen": .bool(true), "workspaceInstructions": .null]),
            "metadata": .object(metadata), "messages": .array(messages), "pendingInput": .array([]),
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

    /// A Cartesian matrix, not timings coupled to session count. Two successive
    /// forks also exercise reuse of the window/presentation without reactivation.
    /// --fork-case <substring> isolates a variant without changing its timing.
    func forkFocusesMountedComposerAfterNavigation() async throws {
        let arguments = CommandLine.arguments
        let filter = arguments.firstIndex(of: "--fork-case").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        }
        var failures: [String] = [], exercised = 0
        for populated in [true, false] {
            for count in 1...2 {
                for sidebar in [false, true] {
                    for slow in [false, true] {
                        let label = "transcript=\(populated ? "populated" : "empty")/roots=\(count)/sidebar=\(sidebar ? "visible" : "hidden")/completion=\(slow ? "slow" : "fast")"
                        if let filter, !label.contains(filter) { continue }
                        exercised += 1
                        do {
                            try await exerciseForks(populated: populated, count: count, sidebar: sidebar, slow: slow)
                            print("PASS fork variant \(label) (two forks)")
                        } catch {
                            failures.append(label)
                            FileHandle.standardError.write(Data("FAIL fork variant \(label): \(error)\n".utf8))
                        }
                    }
                }
            }
        }
        guard exercised > 0, failures.isEmpty else {
            throw CheckFailure(description: "Fork matrix: \(failures.count)/\(exercised) variants failed: \(failures.joined(separator: ", "))")
        }
    }

    private func exerciseForks(populated: Bool, count: Int, sidebar: Bool, slow: Bool) async throws {
        // Enough completed, wrapped transcript content to mount/scroll native rows.
        // Source and fork keep the same message IDs, as a real fork does.
        let messages: [AgentJSON] = populated ? (0..<24).map { index in
            .object(["id": .string(UUID().uuidString), "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                     "text": .string("Synthetic turn \(index)\n" + String(repeating: "Fork transcript fixture. ", count: 12)),
                     "status": .string("completed")])
        } : []
        let fixture = try await SidebarCreationFixture(topLevelCount: count, messages: messages)
        defer { fixture.close() }
        let library = fixture.library, windows = fixture.windows
        let host = NSHostingView(rootView: ForkFocusHost(library: library, windows: windows, initiallyShowsSidebar: sidebar))
        let window = ForkComposerEventWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.mainWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        var retained: [ComposerTextInput.EditorScrollView] = []
        var phase = "initial mount"
        var navigationState = ""
        func diagnostics() -> String { window.diagnostics(library: library, windows: windows, retained: retained) }
        func settle() async throws {
            // Same 100ms event/layout allowance as the original regression. Never
            // extend this on failure, reactivate, or assign a first responder.
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
        }
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw CheckFailure(description: message) }
        }
        do {
            // Activation is a setup precondition only, never a post-fork repair.
            for _ in 0..<100 {
                if NSApp.isActive && window.isKeyWindow { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await settle()
            try check(NSApp.isActive && window.isKeyWindow, "Fixture did not acquire initial active/key window")
            try check(ForkComposerEventWindow.sidebar(in: host)?.isCollapsed == !sidebar, "Initial sidebar state differs from variant")
            try window.postClick(window.visibleEditor())
            try await settle()
            for iteration in 1...2 {
                phase = "fork \(iteration): source /fork typing"
                let source = library.current
                let original = try window.visibleEditor()
                retained.append(original)
                try check(source.draft.isEmpty && source.messages.count == messages.count, "Source draft/transcript precondition failed")
                for (character, code) in [("/", UInt16(44)), ("f", 3), ("o", 31), ("r", 15), ("k", 40)] {
                    window.postKey(character, code: code)
                }
                try await settle()
                try window.checkDelivery()
                try check(source.draft == "/fork" && original.editor.string == "/fork", "Source typing failed")
                window.postKey("\r", code: 36)
                try await fixture.waitForCreation()
                phase = "fork \(iteration): pending creation"
                // Only the fake server completion changes. Sidebar/count/content
                // vary independently; fast never adds a pre-completion delay.
                if slow { try await settle() }
                navigationState = "Before completion:\n" + diagnostics()
                try await fixture.transport.finishCreation(SidebarCreationFixture.snapshot(workspace: fixture.workspace, messages: messages))
                await library.waitForNavigation()
                navigationState += "\nImmediately after navigation (before layout allowance):\n" + diagnostics()
                phase = "fork \(iteration): caret and native input"
                try await settle()
                let fork = try window.visibleEditor()
                retained.append(fork)
                try check(library.current !== source && library.error == nil && library.current.messages.count == messages.count,
                          "Fork did not open the expected transcript")
                var issues: [String] = []
                func observe(_ condition: Bool, _ message: String) {
                    if !condition { issues.append(message + "\n" + diagnostics()) }
                }
                observe(NSApp.isActive && window.isKeyWindow, "Lost active/key state after fork (not repaired by test)")
                observe(fork !== original && fork.editor.isEditable && fork.editor.isSelectable &&
                        window.firstResponder === fork.editor && fork.editor.shouldDrawInsertionPoint &&
                        fork.editor.selectedRange() == NSRange(location: 0, length: 0), "Fork caret unavailable")
                window.postKey("a", code: 0)
                try await settle()
                observe(library.current.draft == "a" && fork.editor.string == "a", "Fork rejected first native typing")
                // Still click/type after a caret failure to distinguish focus-only
                // failures from a disabled/stale editor. Never force fork focus.
                try window.postClick(fork)
                try await settle()
                window.postKey("b", code: 11)
                try await settle()
                observe(library.current.draft == "ab" && fork.editor.string == "ab", "Fork rejected typing after native click")
                try window.checkDelivery()
                if !issues.isEmpty {
                    // Investigation only: preserve the failure even if ordinary
                    // session navigation repairs it. This is not a test retry.
                    if let sourceID = source.currentSessionID, let forkID = library.currentSessionID {
                        windows.openSession(sourceID)
                        await library.waitForNavigation()
                        try await settle()
                        windows.openSession(forkID)
                        await library.waitForNavigation()
                        try await settle()
                        let before = library.current.draft
                        window.postKey("c", code: 8)
                        try await settle()
                        issues.append("Switch away/back: native typing changed draft=\(library.current.draft != before)\n" + diagnostics())
                    }
                    throw CheckFailure(description: issues.joined(separator: "\n"))
                }
                phase = "fork \(iteration): native selection and replacement"
                window.postKey("\u{f702}", code: 123, flags: [.shift])
                window.postKey("\u{f702}", code: 123, flags: [.shift])
                try await settle()
                try check(fork.editor.selectedRange() == NSRange(location: 0, length: 2), "Fork keyboard selection failed")
                window.postKey("r", code: 15)
                try await settle()
                try check(library.current.draft == "r" && fork.editor.selectedRange() == NSRange(location: 1, length: 0),
                          "Fork selection replacement failed")
                // Clear through native selection/backspace, not a binding mutation,
                // so a second /fork begins in the same, already-used composer.
                window.postKey("\u{f702}", code: 123, flags: [.shift])
                window.postKey("\u{7f}", code: 51)
                try await settle()
                try check(library.current.draft.isEmpty && source.draft.isEmpty && fork.editor.string.isEmpty,
                          "Fork native deletion or source draft clearing failed")
                try window.checkDelivery()
                try check(windows.composerFocusRequest == iteration && windows.sidebarRevealRequest == (count == 1 ? 1 : 0),
                          "Fork focus/reveal request count changed")
            }
            let requests = await fixture.transport.creationRequests
            try check(requests == 2, "Expected two explicit fork requests")
        } catch {
            throw CheckFailure(description: "\(phase): \(error)\n\(navigationState)\nAt failure:\n\(diagnostics())")
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
