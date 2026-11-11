import AppKit

@MainActor struct MessageNavigationTests {
    func traversesSentMessagesAndReturnsToBottom() throws {
        _ = NSApplication.shared
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        defer { view.detach() }
        let messages = (0..<20).flatMap { index in
            [Message(role: .user, text: "Sent \(index)"),
             Message(role: .assistant, text: "Reply \(index)")]
        }
        view.update(messages: messages, jumpRequest: 0, bottomInset: 140)
        settle(view)
        // Several recent user bubbles are below the top of the viewport. Up
        // should skip those and move backward, never increase document height.
        let initialBottom = view.contentView.bounds.minY
        let firstTarget = stride(from: 38, through: 0, by: -2).first {
            state.layout.offsets[$0] - 20 < initialBottom - 1
        }!
        try expect(firstTarget < 38)
        for index in stride(from: firstTarget, through: 0, by: -2) {
            let previousY = view.contentView.bounds.minY
            view.navigateSentMessage(.previous)
            settle(view)
            try aligned(index, in: view)
            try expect(view.contentView.bounds.minY < previousY)
            try expect(abs(view.documentView!.frame.height - state.layout.totalHeight - 140) < 1)
            try expect(!state.followsLatest)
        }
        view.navigateSentMessage(.previous)
        try aligned(0, in: view)
        for index in stride(from: 2, through: 38, by: 2) {
            view.navigateSentMessage(.next)
            settle(view)
            let maximum = max(0, state.layout.totalHeight + 140 - view.contentSize.height)
            let expected = min(maximum, state.layout.offsets[index] - 20)
            try expect(abs(view.contentView.bounds.minY - expected) < 1)
            try expect(abs(view.documentView!.frame.height - state.layout.totalHeight - 140) < 1)
        }
        // Down clamps to the natural bottom, even when later user messages cannot
        // reach the top. Repeating the command there must leave the viewport alone.
        view.navigateSentMessage(.next)
        settle(view)
        try expect(state.followsLatest)
        try expect(abs(view.documentView!.frame.height - state.layout.totalHeight - 140) < 1)
        try expect(abs(view.contentView.bounds.maxY - view.documentView!.frame.height) < 1)
        let bottom = view.contentView.bounds.minY
        view.navigateSentMessage(.next)
        try expect(view.contentView.bounds.minY == bottom)
        let previousTarget = stride(from: 38, through: 0, by: -2).first {
            state.layout.offsets[$0] - 20 < bottom - 1
        }!
        for _ in 0..<3 {
            view.navigateSentMessage(.previous)
            settle(view)
            try aligned(previousTarget, in: view)
            try expect(view.contentView.bounds.minY < bottom)
            try expect(abs(view.documentView!.frame.height - state.layout.totalHeight - 140) < 1)
            view.navigateSentMessage(.next)
            settle(view)
            try expect(state.followsLatest && abs(view.contentView.bounds.minY - bottom) < 1)
        }
    }

    func preservesTargetDuringUpdatesAndResumesFromManualScroll() throws {
        _ = NSApplication.shared
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        defer { view.detach() }
        var messages = (0..<30).flatMap { index in
            [Message(role: .user, text: String(repeating: "Sent \(index) ", count: 20)),
             Message(role: .assistant, text: "Reply \(index)")]
        }
        // With enough real content after the last user message, Up still visits it.
        messages[59].text = String(repeating: "Long response that fills the viewport. ", count: 100)
        view.update(messages: messages, jumpRequest: 0, bottomInset: 100)
        view.navigateSentMessage(.previous)
        try aligned(58, in: view)
        view.navigateSentMessage(.previous)
        try aligned(56, in: view)
        messages[59].text += String(repeating: " More response.", count: 60)
        view.update(messages: messages, jumpRequest: 0, bottomInset: 100)
        view.frame.size.width = 450
        settle(view)
        try aligned(56, in: view)
        try expect(!state.followsLatest)

        // A wheel/scrollbar change discards the keyboard cursor. Navigate relative
        // to the new viewport, not the message visited before the manual scroll.
        view.contentView.scroll(to: NSPoint(x: 0, y: state.layout.offsets[20] + 5))
        view.reflectScrolledClipView(view.contentView)
        settle(view)
        view.navigateSentMessage(.next)
        try aligned(22, in: view)
        view.contentView.scroll(to: NSPoint(x: 0, y: state.layout.offsets[20] + 5))
        view.reflectScrolledClipView(view.contentView)
        settle(view)
        view.navigateSentMessage(.previous)
        try aligned(20, in: view)

        state.jumpToLatest()
        view.update(messages: messages, jumpRequest: state.jumpRequest, bottomInset: 100)
        try expect(state.followsLatest)
        try expect(abs(view.contentView.bounds.maxY - view.documentView!.frame.height) < 1)
    }

    func emptySingleAndIndependentTranscripts() throws {
        _ = NSApplication.shared
        let first = TranscriptState(), second = TranscriptState()
        let a = TranscriptScrollView(state: first), b = TranscriptScrollView(state: second)
        for view in [a, b] { view.frame = NSRect(x: 0, y: 0, width: 700, height: 400) }
        defer { a.detach(); b.detach() }
        a.update(messages: [], jumpRequest: 0)
        a.navigateSentMessage(.previous)
        a.navigateSentMessage(.next)
        try expect(a.contentView.bounds.minY == 0)
        let messages = [Message(role: .user, text: "Only sent message"), Message(role: .assistant, text: "Reply")]
        a.update(messages: messages, jumpRequest: 0)
        b.update(messages: messages, jumpRequest: 0)
        a.navigateSentMessage(.previous)
        try aligned(0, in: a)
        try expect(first.followsLatest && second.followsLatest)
        for direction in [MessageNavigationDirection.previous, .next, .previous] {
            a.navigateSentMessage(direction)
            try expect(a.contentView.bounds.minY == 0)
            try expect(a.documentView!.frame.height == a.contentSize.height)
        }
        a.update(messages: messages + [Message(role: .assistant,
            text: String(repeating: "Long response. ", count: 300))], jumpRequest: 0)
        a.navigateSentMessage(.previous)
        try aligned(0, in: a)
        try expect(!first.followsLatest && second.followsLatest)
        a.navigateSentMessage(.next)
        try expect(first.followsLatest)
        a.detach()
        try expect(first.scrollView == nil && second.scrollView === b)
    }

    private func aligned(_ index: Int, in view: TranscriptScrollView) throws {
        try expect(abs(view.state.layout.offsets[index] - view.contentView.bounds.minY - 20) < 1)
    }

    private func settle(_ view: TranscriptScrollView) {
        for _ in 0..<6 { view.layoutSubtreeIfNeeded(); view.refresh() }
    }
}
