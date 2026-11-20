import AppKit

@MainActor struct ThinkingIndicatorTests {
    func responseActivity() throws {
        guard case .object(var fields) = try AgentIntegrationTests.fixture(state: "running") else {
            throw CheckFailure(description: "Invalid thinking fixture")
        }
        fields["approval"] = .null
        fields["activeToolCallID"] = .null
        fields["activeToolName"] = .null
        func visible() throws -> Bool {
            try AgentJSON.object(fields).decoded(AgentSnapshot.self).showsThinkingIndicator
        }
        func assistant(_ text: String, status: String) {
            fields["messages"] = .array([.object([
                "id": .string(UUID().uuidString), "role": .string("assistant"),
                "text": .string(text), "status": .string(status)
            ])])
        }
        assistant("", status: "streaming")
        try expect(visible()) // Initial reasoning placeholder.
        assistant("Answer", status: "streaming")
        try expect(!visible())
        assistant("Answer", status: "completed")
        try expect(visible()) // Between completed output and the next round.
        fields["activeToolCallID"] = .string("call")
        try expect(!visible())
        fields["activeToolCallID"] = .null
        fields["activeToolName"] = .string("wait")
        try expect(!visible())
        fields["activeToolName"] = .null
        fields["messages"] = .array([.object([
            "id": .string(UUID().uuidString), "role": .string("tool"),
            "text": .string("Partial result"), "outcome": .string("running")
        ])])
        try expect(!visible()) // Running delegation results also suppress it.
        assistant("", status: "streaming")
        try expect(visible()) // Tool settled, next inference has no text yet.
        for state in ["awaiting_approval", "cancelling", "completed", "failed", "interrupted"] {
            fields["operation"] = .object(["id": .string(UUID().uuidString), "state": .string(state)])
            try expect(!visible())
        }
        fields["operation"] = .null
        try expect(!visible())
    }

    func documentFooter() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        window.contentView = view
        defer { view.detach(); window.contentView = nil }
        let messages = [Message(role: .assistant, text: String(repeating: "Answer paragraph.\n\n", count: 80))]
        func update(_ visible: Bool) {
            view.update(messages: messages, jumpRequest: 0, bottomInset: 140, showsThinkingIndicator: visible)
            view.layoutSubtreeIfNeeded()
        }
        update(false)
        let originalHeight = view.documentView!.frame.height
        update(true)
        guard let footer = view.thinkingIndicatorFrame else {
            throw CheckFailure(description: "Missing transcript footer")
        }
        try expect(footer.minY == state.layout.totalHeight - 8 + view.topInset)
        try expect(footer.maxY < view.documentView!.frame.height - 140)
        try expect(view.documentView!.frame.height == originalHeight + 40)
        let oldY = footer.minY
        view.contentView.scroll(to: NSPoint(x: 0, y: 0))
        try expect(view.thinkingIndicatorFrame?.minY == oldY) // Document, not viewport coordinates.
        update(false)
        try expect(view.thinkingIndicatorFrame == nil)
        try expect(view.documentView!.frame.height == originalHeight)
    }

    private func snapshotJSON(text: String = "", state: String = "running",
                              operationID: UUID = AgentIntegrationTests.operationID) throws -> AgentJSON {
        guard case .object(var fields) = try AgentIntegrationTests.fixture(state: state) else {
            throw CheckFailure(description: "Invalid thinking fixture")
        }
        fields["approval"] = .null
        fields["operation"] = .object(["id": .string(operationID.uuidString), "state": .string(state)])
        fields["messages"] = .array([.object([
            "id": .string(AgentIntegrationTests.assistantID.uuidString), "role": .string("assistant"),
            "text": .string(text), "status": .string("streaming")
        ])])
        return .object(fields)
    }

    private func snapshot(text: String = "", state: String = "running",
                          operationID: UUID = AgentIntegrationTests.operationID) throws -> AgentSnapshot {
        try snapshotJSON(text: text, state: state, operationID: operationID).decoded(AgentSnapshot.self)
    }

    func delayLifecycle() async throws {
        _ = NSApplication.shared
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: FakeAgentTransport())))
        defer { store.closePresentation() }
        func mount() -> TranscriptScrollView {
            let view = TranscriptScrollView(state: TranscriptState())
            view.update(messages: store.messages, jumpRequest: 0, showsThinkingIndicator: store.showsThinkingIndicator)
            return view
        }

        try store.apply(snapshot())
        let first = mount()
        try expect(first.thinkingIndicatorFrame == nil)
        try await Task.sleep(for: .milliseconds(300))
        first.detach() // Navigation does not close the session or reset its gap.
        try store.apply(snapshot()) // Repeated background state must not restart the delay.
        try await Task.sleep(for: .milliseconds(300))
        let returned = mount()
        try expect(returned.thinkingIndicatorFrame != nil)
        returned.detach()
        let again = mount() // Already eligible on return: no additional 0.5-second delay.
        try expect(again.thinkingIndicatorFrame != nil)
        again.detach()
        first.update(messages: [], jumpRequest: 0, showsThinkingIndicator: true)
        try expect(first.thinkingIndicatorFrame == nil) // Late updates cannot revive old views.

        try store.apply(snapshot(text: "Output"))
        try expect(!store.showsThinkingIndicator) // Activity hides synchronously.
        try store.apply(snapshot())
        try await Task.sleep(for: .milliseconds(300))
        try store.apply(snapshot(text: "More output"))
        try store.apply(snapshot()) // A real new gap needs the full delay.
        try await Task.sleep(for: .milliseconds(300))
        try expect(!store.showsThinkingIndicator) // Cancelled task cannot publish into this gap.
        try await Task.sleep(for: .milliseconds(300))
        try expect(store.showsThinkingIndicator)

        try store.apply(snapshot(operationID: UUID()))
        try expect(!store.showsThinkingIndicator) // New operation, even if terminal state was skipped.
        try store.apply(snapshot(state: "interrupted"))
        try await Task.sleep(for: .milliseconds(600))
        try expect(!store.showsThinkingIndicator)
        try store.apply(snapshot())
        store.closePresentation() // Session teardown, unlike navigation, cancels pending publication.
        try await Task.sleep(for: .milliseconds(600))
        try expect(!store.showsThinkingIndicator)
    }

    func backgroundObservation() async throws {
        let transport = FakeAgentTransport()
        let path = AgentAPI.path(AgentIntegrationTests.conversationID)
        try await transport.reply(path, snapshotJSON())
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        try await store.loadSession(AgentIntegrationTests.conversationID)
        // No transcript and no getter read until after the delay.
        try await Task.sleep(for: .milliseconds(600))
        try expect(store.showsThinkingIndicator)
        try await transport.reply(path, snapshotJSON(text: "Background output"))
        for _ in 0..<200 {
            if store.messages.last?.text == "Background output" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(store.messages.last?.text == "Background output")
        try expect(!store.showsThinkingIndicator)
        try await transport.reply(path, snapshotJSON())
        for _ in 0..<200 {
            if store.messages.last?.text == "" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(store.messages.last?.text == "")
        try expect(!store.showsThinkingIndicator)
        try await Task.sleep(for: .milliseconds(600))
        try expect(store.showsThinkingIndicator)
    }
}
