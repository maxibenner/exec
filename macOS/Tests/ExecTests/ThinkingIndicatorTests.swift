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
        try expect(view.thinkingIndicatorFrame == nil)
        try expect(view.documentView!.frame.height == originalHeight)
        try await Task.sleep(for: .milliseconds(350))
        try expect(view.thinkingIndicatorFrame == nil)
        update(true) // An unchanged idle snapshot must not postpone insertion.
        try await Task.sleep(for: .milliseconds(400))
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

    func delayLifecycle() async throws {
        _ = NSApplication.shared
        let view = TranscriptScrollView(state: TranscriptState())
        defer { view.detach() }
        func update(_ idle: Bool) {
            view.update(messages: [], jumpRequest: 0, showsThinkingIndicator: idle)
        }

        update(true)
        try await Task.sleep(for: .milliseconds(350))
        update(false)
        update(true) // Start a fresh gap; the cancelled task must not insert early.
        try await Task.sleep(for: .milliseconds(350))
        try expect(view.thinkingIndicatorFrame == nil)
        try await Task.sleep(for: .milliseconds(400))
        try expect(view.thinkingIndicatorFrame != nil)
        update(false) // Removal is synchronous, including during the fade-in.
        try expect(view.thinkingIndicatorFrame == nil)

        update(true)
        update(false) // Activity resumes before the delay elapses.
        try await Task.sleep(for: .milliseconds(750))
        try expect(view.thinkingIndicatorFrame == nil)

        update(true)
        view.detach() // A conversation switch must not leave a pending insertion.
        update(true) // Late updates cannot revive a dismantled view.
        try await Task.sleep(for: .milliseconds(750))
        try expect(view.thinkingIndicatorFrame == nil)
    }
}
