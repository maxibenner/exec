import AppKit

/// Check descendants and laid-out glyphs, not just the row's fitting size.
@MainActor struct TranscriptConsistencyTests {
    func coldRowsHaveCompleteTextLayout() async throws {
        _ = NSApplication.shared
        let paragraph = "A **formatted** paragraph with a [link](https://example.com), Unicode 👩🏽‍💻 漢字, and wrapped words.\n\n"
        let fixtures = [
            Message(role: .user, text: String(repeating: "x\n", count: 300)),
            Message(role: .user, text: (0..<500).map { "Line \($0): 👩🏽‍💻 漢字" }.joined(separator: "\n")),
            Message(role: .assistant, text: String(repeating: paragraph, count: 60)),
            Message(role: .assistant, text: "```swift\n" + String(repeating: "let value = 123\n", count: 300) + "```"),
            Message(role: .user, text: String(repeating: "unbrokentoken", count: 1500))
        ]
        for message in fixtures {
            let state = TranscriptState()
            let view = TranscriptScrollView(state: state)
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
            let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.orderFront(nil)
            defer { view.detach(); window.orderOut(nil); window.contentView = nil }
            view.update(messages: [message], jumpRequest: 0, bottomInset: 140)
            try await settle(view)
            for width: CGFloat in [900, 620, 420, 900] {
                window.setContentSize(NSSize(width: width, height: 650))
                try await settle(view)
                let text = try onlyText(in: view)
                let row = view.documentView!.subviews[0]
                let frame = text.convert(text.bounds, to: row)
                let padding: CGFloat = message.role == .user ? 8 : 0
                try expect(abs(frame.minY - padding) < 1)
                try expect(abs(row.bounds.height - frame.maxY - padding) < 1)
                try expect(!text.isVerticallyResizable && text.textLayoutManager == nil)
                let used = text.layoutManager!.usedRect(for: text.textContainer!)
                try expect(abs(ceil(used.height) - text.bounds.height) < 1)
                let end = text.convert(NSPoint(x: 0, y: used.maxY), to: view.documentView)
                try expect(end.y > view.contentView.bounds.minY && end.y <= view.contentView.bounds.maxY - 140)
                try expect(state.followsLatest && abs(view.contentView.bounds.maxY - view.documentView!.bounds.height) < 1)
                let before = used
                // Direct jump and incremental traversal must not complete hidden
                // layout work or change the glyph positions of the same row.
                view.contentView.scroll(to: .zero)
                view.refresh()
                try await settle(view)
                state.jumpToLatest()
                view.update(messages: [message], jumpRequest: state.jumpRequest, bottomInset: 140)
                try await settle(view)
                try expect(text.layoutManager!.usedRect(for: text.textContainer!) == before)
            }
        }
    }

    func widthReflowPreservesReadingCharacter() async throws {
        _ = NSApplication.shared
        for role in [Message.Role.user, .assistant] {
            let message = Message(role: role, text: String(repeating: "Reading position with Unicode 👩🏽‍💻 and long wrapped prose. ", count: 600))
            let state = TranscriptState()
            let view = TranscriptScrollView(state: state)
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
            let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.orderFront(nil)
            defer { view.detach(); window.orderOut(nil); window.contentView = nil }
            view.update(messages: [message], jumpRequest: 0, bottomInset: 140)
            try await settle(view)
            view.contentView.scroll(to: NSPoint(x: 0, y: 2000))
            try await settle(view)
            let text = try onlyText(in: view)
            let layout = text.layoutManager!
            let container = text.textContainer!
            let top = text.convert(NSPoint(x: 0, y: view.contentView.bounds.minY), from: view.documentView).y
            let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: top), in: container)
            var lineRange = NSRange()
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
            let character = layout.characterIndexForGlyph(at: lineRange.location)
            let delta = top - line.minY
            let selection = NSRange(location: character + 10, length: 30)
            text.setSelectedRange(selection)
            for width: CGFloat in [740, 620, 500, 420, 620, 740, 900, 420, 900] {
                window.setContentSize(NSSize(width: width, height: 650))
                try await settle(view)
                let reflowedGlyph = layout.glyphIndexForCharacter(at: character)
                let reflowedLine = layout.lineFragmentRect(forGlyphAt: reflowedGlyph, effectiveRange: nil)
                let y = text.convert(NSPoint(x: 0, y: reflowedLine.minY + delta), to: view.documentView).y
                try expect(abs(view.contentView.bounds.minY - y) < 1)
                try expect(!state.followsLatest && text.selectedRange() == selection)
            }
            try expect(abs(view.contentView.bounds.minY - 2000) < 1)
            if role == .user {
                view.navigateSentMessage(.previous)
                try await settle(view)
                try expect(abs(view.contentView.bounds.minY) < 1)
            }
            state.jumpToLatest()
            view.update(messages: [message], jumpRequest: state.jumpRequest, bottomInset: 140)
            try await settle(view)
            try expect(state.followsLatest && abs(view.contentView.bounds.maxY - view.documentView!.bounds.height) < 1)
        }
    }

    func estimatesAndFirstMarkdownLayoutStayBounded() async throws {
        _ = NSApplication.shared
        let sources = [String(repeating: "x\n", count: 300),
                       (0..<500).map { "Line \($0): 👩🏽‍💻 漢字" }.joined(separator: "\n"),
                       String(repeating: "Long words wrapping within a user bubble. ", count: 600)]
        for width: CGFloat in [380, 580, 820] {
            for source in sources {
                let message = Message(role: .user, text: source)
                var layout = TranscriptLayout()
                layout.update(messages: [message], width: width)
                let measured = LinkedText.measuredSize(of: LinkedText.attributed(AttributedString(source)),
                                                       width: min(600, width - 40) - 24).height + 16
                let ratio = layout.heights[0] / measured
                try expect(ratio > 0.7 && ratio < 1.4)
            }
        }
        let messages = (0..<100).map { _ in Message(role: .user, text: sources[0]) }
        let state = TranscriptState()
        let view = TranscriptScrollView(state: state)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
        defer { view.detach() }
        view.update(messages: messages, jumpRequest: 0)
        try await settle(view)
        let initialHeight = state.layout.totalHeight
        try expect(view.rowMeasurementCount < 10)
        for index in stride(from: 90, through: 0, by: -10) {
            view.contentView.scroll(to: NSPoint(x: 0, y: state.layout.offsets[index]))
            try await settle(view)
            try expect(view.mountedRowCount < 10)
            try expect(abs(state.layout.totalHeight / initialHeight - 1) < 0.1)
        }
        // Soft source breaks must never become a temporary multi-page live row.
        let source = String(repeating: "x\n", count: 300)
        let assistant = Message(role: .assistant, text: source)
        let markdownState = TranscriptState()
        let markdownView = TranscriptScrollView(state: markdownState)
        markdownView.frame = view.frame
        defer { markdownView.detach() }
        markdownView.update(messages: [assistant], jumpRequest: 0, bottomInset: 140)
        markdownView.layoutSubtreeIfNeeded()
        markdownView.refresh()
        let firstHeight = markdownState.layout.totalHeight
        let rendered = MarkdownText.render(MarkdownDocument.parse(source))
        let liveText = try onlyText(in: markdownView)
        try expect(liveText.string == rendered.string)
        try expect(markdownState.layout.heights[0] == LinkedText.measuredSize(of: rendered, width: markdownState.layout.width).height)
        try await settle(markdownView)
        try expect(markdownState.layout.totalHeight == firstHeight)
    }

    private func onlyText(in view: NSView) throws -> LinkedText.TextView {
        if let text = view as? LinkedText.TextView { return text }
        for child in view.subviews {
            if let text = try? onlyText(in: child) { return text }
        }
        throw CheckFailure(description: "Missing linked transcript text")
    }

    private func settle(_ view: TranscriptScrollView) async throws {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            view.refresh()
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
