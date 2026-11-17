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
        messages += [sent, Message(role: .assistant, text: "", status: .streaming)]
        update(view, messages)
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

        // A fast response can be published in the same update as the next send.
        let next = Message(role: .user, text: "Another question")
        messages += [next, Message(role: .assistant, text: "Already answering", status: .streaming)]
        update(view, messages)
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
        update(view, messages)
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
        update(view, messages)
        try expect(abs(view.contentView.bounds.minY - y) < 1 && !state.followsLatest)

        state.jumpToLatest()
        update(view, messages)
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
            update(view, messages)
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
            update(view, messages)
            try aligned(next, in: view)
            try expect(!state.followsLatest && state.sentMessageID == next.id)
        }
    }

    func anchorsBeforeInitialLayout() throws {
        _ = NSApplication.shared
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        defer { view.detach() }
        // Sends can arrive before AppKit provides a nonzero viewport.
        view.update(messages: [], jumpRequest: 0)
        let sent = Message(role: .user, text: "First question")
        let messages = [sent, Message(role: .assistant, text: "", status: .streaming)]
        view.update(messages: messages, jumpRequest: 0)
        view.frame.size = NSSize(width: 700, height: 500)
        update(view, messages)
        try aligned(sent, in: view)
        try expect(!state.followsLatest)
    }

    private func update(_ view: TranscriptScrollView, _ messages: [Message]) {
        view.update(messages: messages, jumpRequest: view.state.jumpRequest, bottomInset: 100)
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); view.refresh() }
    }

    private func aligned(_ message: Message, in view: TranscriptScrollView) throws {
        let index = view.state.layout.ids.firstIndex(of: message.id)!
        try expect(abs(view.state.layout.offsets[index] - view.contentView.bounds.minY - 20) < 1)
    }
}
