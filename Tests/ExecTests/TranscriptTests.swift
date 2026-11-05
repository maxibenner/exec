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

    func preservesNearBottomScrolling() throws {
        _ = NSApplication.shared
        let messages = (0..<100).map { Message(role: .user, text: "Message \($0)") }
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        defer { view.detach() }
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.update(messages: messages, jumpRequest: 0)
        view.layoutSubtreeIfNeeded(); view.refresh()
        let bottom = view.documentView!.bounds.height - view.contentView.bounds.height
        // Being near the bottom should enable following future content without
        // snapping the current gesture to the edge.
        view.contentView.setBoundsOrigin(NSPoint(x: 0, y: bottom - 15))
        view.refresh()
        let remaining = view.documentView!.bounds.height - view.contentView.bounds.maxY
        try expect(state.followsLatest && abs(remaining - 15) < 1)
        // Explicit navigation must still reach the edge after a user scroll.
        state.jumpToLatest()
        view.update(messages: messages, jumpRequest: state.jumpRequest)
        try expect(abs(view.contentView.bounds.maxY - view.documentView!.bounds.height) < 1)
    }

    func expandedToolContentStaysInsideCommittedRowBounds() throws {
        _ = NSApplication.shared
        let output = (0..<12).map { "Output line \($0)" }.joined(separator: "\n")
        let result = ToolResult(call: ToolCall(id: "shell", name: "shell", arguments: "{}"), text: output)
        let shell = Message(role: .tool, text: output, toolResult: result)
        let messages = [shell, Message(role: .assistant, text: "This reply must never be covered by shell output.")]
        let state = TranscriptState()
        state.followsLatest = false
        state.expanded[shell.id] = true
        let view = TranscriptScrollView(state: state)
        defer { view.detach() }
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.update(messages: messages, jumpRequest: 0)
        view.layoutSubtreeIfNeeded(); view.refresh()
        let rows = view.documentView!.subviews.sorted { $0.frame.minY < $1.frame.minY }
        try expect(rows.count == 2)
        let row = rows[0]
        let fullFrame = row.frame
        let neighborFrame = rows[1].frame
        try expect(fullFrame.height > 200 && neighborFrame.minY >= fullFrame.maxY)
        try expect(row.clipsToBounds && row.layer?.masksToBounds == true)
        try expect(row.subviews.count == 1)
        let hosted = row.subviews[0]
        func fields(in view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField { return [field] }
            return view.subviews.flatMap { fields(in: $0) }
        }
        func bodyFrames() throws -> (arguments: NSRect, output: NSRect) {
            let fields = fields(in: hosted)
            guard let arguments = fields.first(where: { $0.stringValue == "{}" }),
                  let outputField = fields.first(where: { $0.stringValue == output }) else {
                throw CheckFailure(description: "Expected selectable shell arguments and output")
            }
            return (arguments.convert(arguments.bounds, to: row), outputField.convert(outputField.bounds, to: row))
        }
        let fullBody = try bodyFrames()

        // Reproduce the interval between SwiftUI expanding/measuring its content
        // and the transcript committing a larger row frame. The native boundary
        // must remain small even if the hosted view uses its full natural height.
        // The hosting view can also receive the stale, collapsed height while
        // SwiftUI has already inserted the expanded body. Its text must stay
        // below the header rather than centering/overlapping within that height.
        for height in [CGFloat(60), fullFrame.height] {
            hosted.setFrameSize(NSSize(width: fullFrame.width, height: height))
            hosted.layoutSubtreeIfNeeded()
            let body = try bodyFrames()
            try expect(abs(body.arguments.minY - fullBody.arguments.minY) < 1)
            try expect(body.output.minY >= body.arguments.maxY)
            try expect(abs(body.output.height - fullBody.output.height) < 1)
        }
        row.setFrameSize(NSSize(width: fullFrame.width, height: 60))
        hosted.frame = NSRect(origin: .zero, size: fullFrame.size)
        let measured = row.fittingSize
        try expect(measured.height > 200 && row.frame.height == 60)
        try expect(hosted.visibleRect.height <= 60)
        try expect(rows[1].frame == neighborFrame)

        view.refresh()
        view.layoutSubtreeIfNeeded(); view.refresh()
        try expect(abs(row.frame.height - measured.height) < 1)
        try expect(rows[1].frame.minY >= row.frame.maxY)
        try expect(!state.followsLatest && state.expanded[shell.id] == true)
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
        restored.update(messages: messages, jumpRequest: 0, bottomInset: 180)
        try expect(state.layout.anchor(at: restored.contentView.bounds.minY) == anchor)
        state.jumpToLatest()
        restored.update(messages: messages, jumpRequest: state.jumpRequest, bottomInset: 180)
        try expect(abs(restored.contentView.bounds.maxY - restored.documentView!.bounds.height) < 2)
        let lastBottom = state.layout.offsets.last! + state.layout.heights.last!
        try expect(lastBottom <= restored.contentView.bounds.maxY - 180)
        restored.detach()
    }
}
