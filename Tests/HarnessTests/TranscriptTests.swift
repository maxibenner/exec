import AppKit

@MainActor struct TranscriptTests {
    func geometryPreservesAnchors() throws {
        let messages = (0..<1_000).map { Message(role: .user, text: "Message \($0)") }
        var layout = TranscriptLayout()
        layout.update(messages: messages, width: 700)
        let originalY = layout.offsets[500] + 10
        let anchor = layout.anchor(at: originalY)!
        try expect(anchor.id == messages[500].id && anchor.offset == 10)
        let gapY = layout.offsets[500] + layout.heights[500] + 12
        try expect(layout.position(of: layout.anchor(at: gapY)!) == gapY)
        let originalHeight = layout.heights[100]
        layout.measure(messages[100].id, height: originalHeight + 200)
        try expect(layout.position(of: anchor) == originalY + 200)
        let range = layout.visibleRange(y: originalY + 200, height: 600, overscan: 300)
        try expect(range.contains(500) && range.count < 40)
        layout.update(messages: messages + [Message(role: .assistant, text: "New")], width: 700)
        try expect(layout.position(of: anchor) == originalY + 200)
        layout.update(messages: messages, width: 400)
        try expect(layout.anchor(at: layout.position(of: anchor)!) == anchor)
        layout.update(messages: [], width: 400)
        try expect(layout.visibleRange(y: 0, height: 600, overscan: 300).isEmpty && layout.anchor(at: 0) == nil)
    }

    func mountsBoundedRowsAndRestoresPosition() async throws {
        _ = NSApplication.shared
        let messages = (0..<1_000).map { Message(role: .user, text: "Message \($0): a small stable row") }
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.update(messages: messages, jumpRequest: 0)
        view.layoutSubtreeIfNeeded(); view.refresh()
        try expect(view.mountedRowCount > 0 && view.mountedRowCount < 40)
        try expect(abs(view.contentView.bounds.maxY - view.documentView!.bounds.height) < 2)
        view.contentView.scroll(to: NSPoint(x: 0, y: state.layout.offsets[500] + 8))
        view.refresh()
        try expect(!state.followsLatest)
        let anchor = state.layout.anchor(at: view.contentView.bounds.minY)!
        try expect(anchor.id == messages[500].id && abs(anchor.offset - 8) < 1)
        view.update(messages: messages + [Message(role: .assistant, text: "A new response")], jumpRequest: 0)
        try expect(state.layout.anchor(at: view.contentView.bounds.minY) == anchor)
        view.detach()
        try expect(view.mountedRowCount == 0)
        let restored = TranscriptScrollView(state: state)
        restored.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        restored.update(messages: messages, jumpRequest: 0)
        restored.layoutSubtreeIfNeeded(); restored.refresh()
        try expect(state.layout.anchor(at: restored.contentView.bounds.minY) == anchor)
        try expect(restored.mountedRowCount < 40)
        state.jumpToLatest()
        restored.update(messages: messages, jumpRequest: state.jumpRequest)
        try expect(abs(restored.contentView.bounds.maxY - restored.documentView!.bounds.height) < 2)
        restored.detach()
    }
}
