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
