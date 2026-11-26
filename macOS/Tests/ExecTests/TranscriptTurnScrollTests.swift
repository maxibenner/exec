import AppKit

@MainActor struct TranscriptTurnScrollTests {
    func anchorsNewSendsWhileResponsesFillSpace() throws {
        _ = NSApplication.shared
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        defer { view.detach() }
        view.frame.size = NSSize(width: 700, height: 500)
        view.updateHeaderInset(52)
        var messages = (0..<8).flatMap {
            [Message(role: .user, text: "Earlier question \($0)"),
             Message(role: .assistant, text: "Earlier answer \($0)")]
        }
        update(view, messages)
        let sent = Message(role: .user, text: "A new question")
        update(view, messages, immediateSendID: sent.id)
        try expect(state.followsLatest && state.sentMessageID == nil)
        messages += [sent, Message(role: .assistant, text: "", status: .streaming)]
        update(view, messages, immediateSendID: sent.id)
        try aligned(sent, in: view)
        try expect(!state.followsLatest)
        let documentHeight = view.documentView!.frame.height
        try expect(documentHeight > state.layout.totalHeight + 100 + view.topInset)
        // Separate Markdown paragraphs so this fixture actually exceeds a viewport;
        // single newlines are soft breaks and collapse into one short paragraph.
        for text in ["A short answer.", String(repeating: "More answer.\n\n", count: 60)] {
            messages[messages.count - 1].text = text
            update(view, messages)
            try aligned(sent, in: view)
            try expect(!state.followsLatest)
        }
        try expect(view.documentView!.frame.height > documentHeight)
        try expect(abs(view.documentView!.frame.height - state.layout.totalHeight - 100 - view.topInset) < 1)

        // The first response chunk can arrive in the snapshot before the receipt.
        let next = Message(role: .user, text: "Another question")
        messages += [next, Message(role: .assistant, text: "Already answering", status: .streaming)]
        update(view, messages, immediateSendID: sent.id)
        try aligned(sent, in: view)
        update(view, messages, immediateSendID: next.id)
        try aligned(next, in: view)
        let y = view.contentView.bounds.minY
        let shortHeight = view.documentView!.frame.height
        // A cancelled or failed short answer leaves the reading surface in place.
        for status in [Message.Status.interrupted, .failed, .complete] {
            messages[messages.count - 1].status = status
            update(view, messages)
            try expect(abs(view.contentView.bounds.minY - y) < 1)
            try expect(abs(view.documentView!.frame.height - shortHeight) < 1)
            try expect(!state.followsLatest)
        }
    }

    func preservesReadingAndSupportsExplicitFollowing() throws {
        _ = NSApplication.shared
        let state = TranscriptState()
        state.jumpToLatest()
        var view = TranscriptScrollView(state: state)
        defer { view.detach() }
        view.frame.size = NSSize(width: 700, height: 500)
        update(view, [])
        let sent = Message(role: .user, text: "Question")
        var messages = [sent, Message(role: .assistant, text: "Short answer", status: .streaming)]
        update(view, messages, immediateSendID: sent.id)
        try aligned(sent, in: view)
        for size in [NSSize(width: 450, height: 650), NSSize(width: 800, height: 400)] {
            view.frame.size = size
            view.updateHeaderInset(52)
            update(view, messages)
            try aligned(sent, in: view)
            try expect(!state.followsLatest)
        }
        view.detach()
        view = TranscriptScrollView(state: state)
        view.frame.size = NSSize(width: 650, height: 500)
        view.updateHeaderInset(52)
        update(view, messages)
        try aligned(sent, in: view)
        try expect(!state.followsLatest)
        messages[1].text = String(repeating: "Response line.\n\n", count: 80)
        update(view, messages)
        try aligned(sent, in: view)
        view.withReaderScroll { view.contentView.scroll(to: NSPoint(x: 0, y: 180)) }
        view.reflectScrolledClipView(view.contentView)
        view.refresh()
        let y = view.contentView.bounds.minY
        try expect(abs(y - 180) < 1)
        messages[1].text += String(repeating: "More response.\n\n", count: 20)
        update(view, messages, immediateSendID: sent.id)
        try expect(abs(view.contentView.bounds.minY - y) < 1 && !state.followsLatest)

        view.detach()
        view = TranscriptScrollView(state: state)
        view.frame.size = NSSize(width: 650, height: 500)
        view.updateHeaderInset(52)
        update(view, messages, immediateSendID: sent.id)
        try expect(abs(view.contentView.bounds.minY - y) < 1 && !state.followsLatest)

        state.jumpToLatest()
        update(view, messages, immediateSendID: sent.id)
        try expect(state.followsLatest && state.sentMessageID == nil)
        try expect(abs(view.contentView.bounds.maxY - view.documentView!.frame.height) < 1)
        messages[1].text += "Final line.\n"
        update(view, messages)
        try expect(abs(view.contentView.bounds.maxY - view.documentView!.frame.height) < 1)
    }

    func resumesFollowingOnlyAfterScrollingDownToBottom() throws {
        _ = NSApplication.shared
        // Cover both a short answer with reserved blank space and a response
        // that has naturally grown beyond the fold without user interaction.
        for longResponse in [false, true] {
            let state = TranscriptState()
            let view = TranscriptScrollView(state: state)
            defer { view.detach() }
            view.frame.size = NSSize(width: 700, height: 500)
            view.updateHeaderInset(52)
            var messages = [Message(role: .user, text: "Earlier question"),
                            Message(role: .assistant, text: "Earlier answer")]
            update(view, messages)
            let sent = Message(role: .user, text: "New question")
            messages += [sent, Message(role: .assistant, text: "", status: .streaming)]
            update(view, messages, immediateSendID: sent.id)
            let responseIndex = messages.count - 1
            for count in longResponse ? [1, 10, 40] : [1] {
                messages[responseIndex].text = String(repeating: "Response paragraph.\n\n", count: count)
                update(view, messages)
                try aligned(sent, in: view)
                try expect(!state.followsLatest && state.sentMessageID == sent.id)
            }
            func scroll(to y: CGFloat) {
                view.withReaderScroll { view.contentView.scroll(to: NSPoint(x: 0, y: y)) }
                view.reflectScrolledClipView(view.contentView)
                view.refresh()
            }
            // A bounds notification without downward movement is not an opt-in,
            // even when the top-anchored short turn is already at document bottom.
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: view.contentView)
            view.refresh()
            try expect(!state.followsLatest)
            scroll(to: view.contentView.bounds.minY - 20)
            try expect(!state.followsLatest)
            let bottom = view.documentView!.frame.height - view.contentView.bounds.height
            scroll(to: bottom - 10)
            try expect(!state.followsLatest)
            scroll(to: bottom)
            try expect(state.followsLatest && state.sentMessageID == nil)
            messages[responseIndex].text += String(repeating: "Additional response.\n\n", count: 30)
            update(view, messages)
            try expect(abs(view.contentView.bounds.maxY - view.documentView!.frame.height) < 1)
            messages.append(Message(role: .assistant, text: "A later event", status: .streaming))
            update(view, messages)
            try expect(state.followsLatest)
            try expect(abs(view.contentView.bounds.maxY - view.documentView!.frame.height) < 1)
            scroll(to: view.contentView.bounds.minY - 100)
            let readingY = view.contentView.bounds.minY
            try expect(!state.followsLatest)
            messages[messages.count - 1].text += String(repeating: "More content.\n\n", count: 10)
            update(view, messages)
            try expect(!state.followsLatest && abs(view.contentView.bounds.minY - readingY) < 1)
            let next = Message(role: .user, text: "Next question")
            messages.append(next)
            update(view, messages, immediateSendID: next.id)
            try aligned(next, in: view)
            try expect(!state.followsLatest && state.sentMessageID == next.id)
        }
    }

    func anchorsBeforeInitialLayout() throws {
        _ = NSApplication.shared
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        defer { view.detach() }
        // The receipt and first rows can arrive before AppKit provides a viewport.
        let sent = Message(role: .user, text: "First question")
        let messages = [sent, Message(role: .assistant, text: "", status: .streaming)]
        view.update(messages: messages, jumpRequest: 0, immediateSendID: sent.id)
        view.frame.size = NSSize(width: 700, height: 500)
        update(view, messages, immediateSendID: sent.id)
        try aligned(sent, in: view)
        try expect(!state.followsLatest)
    }

    func queuedPromotionPreservesReadingAndBottomFollowing() async throws {
        _ = NSApplication.shared
        let transport = FakeAgentTransport()
        try await transport.reply("/v1/providers", .array([.object([
            "id": .string("deepseek"), "name": .string("Test"), "connected": .bool(true)])]))
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        try await provider.refreshConnections()
        let store = ChatStore(provider: provider, sleepPrevention: SessionSleepPrevention(begin: { NSObject() }, end: { _ in }))
        store.installModels([ChatModel(id: "deepseek/test", name: "Test")])
        defer { store.closePresentation() }

        func row(_ role: String, _ text: String, id: UUID = UUID(), status: String = "completed") -> AgentJSON {
            .object(["id": .string(id.uuidString.lowercased()), "role": .string(role),
                     "text": .string(text), "status": .string(status)])
        }
        guard case .object(var snapshot) = try AgentIntegrationTests.fixture(state: "completed", result: true) else {
            throw CheckFailure(description: "Invalid snapshot fixture")
        }
        let history = (0..<16).flatMap { [row("user", "Question \($0)"), row("assistant", "Answer \($0)")] }
        snapshot["messages"] = .array(history)
        try store.apply(AgentJSON.object(snapshot).decoded(AgentSnapshot.self))

        let reader = TranscriptScrollView(state: TranscriptState())
        let follower = TranscriptScrollView(state: TranscriptState())
        defer { reader.detach(); follower.detach() }
        func present(_ view: TranscriptScrollView) {
            update(view, store.messages, immediateSendID: store.latestImmediateSendID,
                   bottomInset: store.queuedMessages.isEmpty ? 100 : 172)
        }
        for view in [reader, follower] {
            view.frame.size = NSSize(width: 700, height: 500)
            present(view)
        }
        let path = AgentAPI.path(AgentIntegrationTests.conversationID)
        let operationID = UUID().uuidString.lowercased()
        let sent = Message(role: .user, text: "Same prompt")
        // A fast, unobserved promotion can coexist with the local send. Even if
        // the text is identical, only the exact receipt ID may top-anchor.
        let turn = history + [row("user", sent.text, id: sent.id), row("user", sent.text), row("assistant", "Answer so far")]
        snapshot["messages"] = .array(turn)
        snapshot["operation"] = .object(["id": .string(operationID), "state": .string("running")])
        try await transport.reply(path, .object(snapshot))
        try await transport.reply(path + "/turns", .object(["operationID": .string(operationID),
                                                          "messageID": .string(sent.id.uuidString.lowercased())]))
        store.draft = sent.text
        store.send()
        await store.waitUntilIdle()
        present(reader)
        try aligned(sent, in: reader)
        present(follower)
        follower.state.jumpToLatest()
        present(follower)

        let queuedID = UUID(), responseID = UUID()
        let queued = row("user", "Queued follow-up", id: queuedID)
        snapshot["pendingInput"] = .array([queued])
        try await transport.reply(path, .object(snapshot))
        try await transport.reply(path + "/steer", .object(["operationID": .string(operationID), "messageID": queued["id"]]))
        store.draft = "Queued follow-up"
        store.send()
        await store.waitUntilIdle()
        try expect(store.queuedMessages.map(\.id) == [queuedID] && !store.messages.contains { $0.id == queuedID })
        present(reader)
        present(follower)
        // Measuring newly mounted history can correct its absolute Y. Enter
        // a known row, then capture the settled reading position.
        let historyID = reader.state.layout.ids[6]
        let historyY = reader.state.layout.offsets[6] + 5
        reader.withReaderScroll { reader.contentView.scroll(to: NSPoint(x: 0, y: historyY)) }
        reader.reflectScrolledClipView(reader.contentView)
        present(reader)
        let readingY = reader.contentView.bounds.minY
        try expect(reader.state.anchor?.id == historyID && !reader.state.followsLatest)

        snapshot["pendingInput"] = .array([])
        for text in ["Continuing", "Continuing\n\n" + String(repeating: "More answer.\n\n", count: 30)] {
            snapshot["messages"] = .array(turn + [queued, row("assistant", text, id: responseID, status: "streaming")])
            try await transport.reply(path, .object(snapshot))
            try await SessionLifecycleTests.wait("promoted input and live response") { store.messages.last?.text == text }
            try expect(store.queuedMessages.isEmpty && store.messages.filter { $0.id == queuedID }.count == 1)
            present(reader)
            present(follower)
            try expect(abs(reader.contentView.bounds.minY - readingY) < 1 && reader.state.sentMessageID == sent.id)
            try expect(follower.state.followsLatest && follower.state.sentMessageID == nil)
            try expect(abs(follower.contentView.bounds.maxY - follower.documentView!.frame.height) < 1)
        }
        let posts = await transport.requests.filter { $0.method == "POST" }
        try expect(posts.map(\.path) == [path + "/turns", path + "/steer"])
    }

    private func update(_ view: TranscriptScrollView, _ messages: [Message], immediateSendID: UUID? = nil,
                        bottomInset: CGFloat = 100) {
        view.update(messages: messages, jumpRequest: view.state.jumpRequest, bottomInset: bottomInset,
                    immediateSendID: immediateSendID)
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); view.refresh() }
    }

    private func aligned(_ message: Message, in view: TranscriptScrollView) throws {
        guard let index = view.state.layout.ids.firstIndex(of: message.id) else {
            throw CheckFailure(description: "Missing user row in the transcript")
        }
        try expect(abs(view.state.layout.offsets[index] - view.contentView.bounds.minY - 20) < 1)
    }
}
