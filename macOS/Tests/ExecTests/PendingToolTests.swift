import Foundation
import SwiftUI

@MainActor struct PendingToolTests {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Tool card operation did not settle")
    }

    private func calls() -> [ToolCall] {
        ["first", "second"].map {
            ToolCall(id: $0, name: "fetch_content", arguments: "{\"url\":\"https://example.com/\($0)\"}")
        }
    }

    func showsOnlyCurrentCallAndUpdatesInPlace() async throws {
        let provider = FakeProvider()
        let calls = calls()
        provider.scripted = [calls.map(ChatEvent.toolCall) + [.completed], [.text("Done"), .completed]]
        var started = 0
        var released = 0
        let store = ChatStore(provider: provider, fetchContent: { _ in
            let number = await MainActor.run { started += 1; return started }
            while await MainActor.run(body: { released < number }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            if number == 1 { throw ExecError("Page unavailable") }
            return "Fetched second page"
        })
        store.selectedModel = "test"
        store.draft = "Inspect"; store.send()
        try await wait { started == 1 }
        let first = store.messages.last!
        try expect(first.pendingTool?.call == calls[0] && first.toolResult == nil && first.text.isEmpty)
        try expect(store.messages.filter { $0.role == .tool }.count == 1)
        try expect(provider.inputs.count == 1)
        released = 1
        try await wait { started == 2 }
        let second = store.messages.last!
        try expect(second.pendingTool?.call == calls[1] && second.toolResult == nil)
        try expect(store.messages.first { $0.id == first.id }?.toolResult?.text.hasPrefix("Tool error: Page unavailable") == true)
        try expect(store.messages.filter { $0.role == .tool }.count == 2)
        // A later user message must not move the active card when its result arrives.
        store.draft = "Use those results"; store.send()
        let userID = store.messages.last!.id
        released = 2
        await store.waitUntilIdle()
        try expect(store.error == nil && started == 2 && provider.inputs.count == 2)
        let rows = store.messages.filter { $0.role == .tool }
        try expect(rows.map(\.id) == [first.id, second.id])
        try expect(rows.allSatisfy { $0.pendingTool == nil && $0.status == .complete })
        try expect(rows[1].toolResult?.text == "Fetched second page")
        try expect(store.messages.firstIndex { $0.id == second.id }! < store.messages.firstIndex { $0.id == userID }!)
        try expect(provider.inputs[1].compactMap(\.toolResult).map(\.call.id) == calls.map(\.id))
        try expect(provider.inputs.flatMap { $0 }.allSatisfy { $0.pendingTool == nil })
    }

    func cancellationAndRecoveryKeepQueuedCallsHidden() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        let calls = calls()
        provider.scripted = [calls.map(ChatEvent.toolCall) + [.completed]]
        var attempts = 0
        let store = ChatStore(provider: provider, sessions: sessions, newConversation: true, fetchContent: { _ in
            await MainActor.run { attempts += 1 }
            while true { try await Task.sleep(for: .milliseconds(5)) }
        })
        store.selectedModel = "test"
        store.draft = "Inspect"; store.send()
        try await wait { attempts == 1 }
        let id = store.messages.last!.id
        var interrupted = try await sessions.load(id: store.currentSessionID)!
        try expect(interrupted.messages.last?.pendingTool?.call == calls[0])
        try expect(interrupted.history.allSatisfy { $0.pendingTool == nil })
        try expect(interrupted.recoverInterruptedTurn())
        let recovered = interrupted.messages.filter { $0.role == .tool }
        try expect(recovered.count == 1 && recovered[0].id == id)
        try expect(recovered[0].pendingTool == nil && recovered[0].toolResult?.text == FetchContentTool.interrupted)
        try expect(interrupted.history.compactMap(\.toolResult).count == 2)
        try expect(!interrupted.recoverInterruptedTurn())

        store.stop()
        await store.waitUntilIdle()
        try expect(attempts == 1 && provider.inputs.count == 1)
        let rows = store.messages.filter { $0.role == .tool }
        try expect(rows.count == 1 && rows[0].id == id && rows[0].pendingTool == nil)
        let saved = try await sessions.load(id: store.currentSessionID)!
        try expect(saved.history.compactMap(\.toolResult).map(\.call.id) == calls.map(\.id))
        try expect(saved.messages.filter { $0.role == .tool }.count == 1)
        let restoredProvider = FakeProvider()
        let restored = ChatStore(provider: restoredProvider, sessions: sessions, newConversation: true)
        restored.openSession(store.currentSessionID!, loadModels: false)
        await restored.waitUntilIdle()
        try expect(restored.messages == saved.messages && restoredProvider.inputs.isEmpty)
    }

    func checkpointRechecksCancellationAndNewInput() async throws {
        for cancel in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let provider = FakeProvider()
            provider.scripted = [calls().map(ChatEvent.toolCall) + [.completed], [.text("Reconsidered"), .completed]]
            var attempts = 0
            let store = ChatStore(provider: provider, sessions: SessionStore(directory: root),
                                  newConversation: true, fetchContent: { _ in
                await MainActor.run { attempts += 1 }
                return "Unexpected execution"
            })
            var injected = false
            store.didCheckpoint = { [weak store] in
                guard let store, !injected, store.messages.contains(where: { $0.pendingTool != nil }) else { return }
                injected = true
                if cancel { store.stop() }
                else { store.draft = "Stop fetching"; store.send() }
            }
            store.selectedModel = "test"
            store.draft = "Inspect"; store.send()
            await store.waitUntilIdle()
            try expect(injected && attempts == 0)
            let rows = store.messages.filter { $0.role == .tool }
            try expect(rows.count == 1 && rows[0].pendingTool == nil)
            if !cancel {
                try expect(rows[0].toolResult?.text == ToolExecutor.supersededByInput)
                try expect(provider.inputs.last?.compactMap(\.toolResult).count == 2)
            } else {
                try expect(provider.inputs.count == 1)
            }
        }
    }

    func approvalCardExistsBeforeDecision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FakeProvider()
        let call = ToolCall(id: "shell", name: "shell", arguments: #"{"command":"touch must-not-exist"}"#)
        provider.scripted = [[.toolCall(call), .completed], [.text("Denied"), .completed]]
        let store = ChatStore(provider: provider, newConversation: true, workspace: try Workspace.load(root))
        store.selectedModel = "test"
        store.setAutoApproveTools(false)
        store.draft = "Do work"; store.send()
        try await wait { store.tools.pendingApproval != nil }
        let row = store.messages.last!
        try expect(row.pendingTool?.call == call && row.pendingTool?.isAwaitingApproval == true)
        try expect(row.toolResult == nil)
        store.tools.resolveApproval(id: store.tools.pendingApproval!.id, approved: false)
        await store.waitUntilIdle()
        let result = store.messages.first { $0.id == row.id }!
        try expect(result.pendingTool == nil && result.toolResult?.text.hasPrefix("User denied") == true)
        try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-exist").path))
    }

    func pendingPresentationHasInputsWithoutOutput() throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhancedUI) }
        func texts(_ element: any NSAccessibilityProtocol) -> [String] {
            let own = (element.accessibilityValue() as? String).map { [$0] } ?? []
            return own + (element.accessibilityChildren() ?? []).flatMap {
                ($0 as? any NSAccessibilityProtocol).map(texts) ?? []
            }
        }
        for call in [
            ToolCall(id: "shell", name: "shell", arguments: #"{"command":"swift test"}"#),
            ToolCall(id: "image", name: "generate_image", arguments: #"{"prompt":"A tree","transparent_background":false}"#),
            ToolCall(id: "search", name: "web_search", arguments: #"{"query":"Swift documentation"}"#)
        ] {
            let state = TranscriptState()
            let id = UUID()
            state.expanded[id] = true
            let host = NSHostingView(rootView: ToolMessageView(call: call, result: nil,
                isAwaitingApproval: false, state: state, messageID: id).frame(width: 700))
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.orderOut(nil); window.contentView = nil }
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let values = texts(host)
            let presentation = ToolPresentation(call: call)
            try expect(!presentation.inputs.isEmpty && presentation.detail == nil)
            try expect(presentation.inputs.allSatisfy { values.contains($0.text) })
            try expect(!values.contains("No output") && !values.contains("Output") && !values.contains("Result"))
        }
    }
}
