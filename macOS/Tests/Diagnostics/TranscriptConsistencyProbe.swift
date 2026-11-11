import AppKit
import SwiftUI

// Opt-in investigation, not part of the regression runner. Uses synthetic text
// and native windows only: no providers, sessions, credentials or live requests.
// Build/run instructions and interpretation are in docs/transcript-consistency.md.
@main struct TranscriptConsistencyProbe {
    @MainActor final class Fixture {
        let state = TranscriptState()
        let view: TranscriptScrollView
        let window: NSWindow

        init() {
            view = TranscriptScrollView(state: state)
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 650)
            window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Synthetic transcript investigation"
            window.contentView = view
            window.orderFront(nil)
        }

        func close() {
            view.detach()
            window.orderOut(nil)
            window.contentView = nil
        }

        func settle(turns: Int = 20) async throws {
            for _ in 0..<turns {
                view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func sample(_ label: String) {
            let doc = view.documentView!
            print("\(label): width=\(view.contentSize.width) y=\(view.contentView.bounds.minY) document=\(doc.frame.height) bottomDistance=\(doc.frame.height - view.contentView.bounds.maxY) followsLatest=\(state.followsLatest) knob=\(view.verticalScroller?.knobProportion ?? -1)")
            for row in doc.subviews.sorted(by: { $0.frame.minY < $1.frame.minY }) {
                for text in TranscriptConsistencyProbe.texts(row) {
                    let rect = row.convert(text.bounds, from: text)
                    print("  rowHeight=\(row.frame.height) textTop=\(rect.minY) textHeight=\(rect.height) textBottomPadding=\(row.frame.height - rect.maxY) assignedTextHeight=\(text.superview?.bounds.height ?? -1) characters=\(text.string.count)")
                }
            }
        }
    }

    @MainActor static func texts(_ view: NSView) -> [LinkedText.TextView] {
        if let text = view as? LinkedText.TextView { return [text] }
        return view.subviews.flatMap { texts($0) }
    }

    @MainActor static func longMultiline() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let messages = [Message(role: .user, text: String(repeating: "x\n", count: 300))]
        fixture.view.update(messages: messages, jumpRequest: 0, bottomInset: 140)
        try await fixture.settle()
        fixture.sample("multiline bottom")
        fixture.view.contentView.scroll(to: NSPoint(x: 0, y: 20))
        fixture.view.refresh()
        try await fixture.settle(turns: 100)
        fixture.sample("multiline top after two seconds")
        // Diagnostic intervention only, not a production fix: establish whether
        // native self-resizing is responsible for the assigned/live height split.
        for text in texts(fixture.view) {
            text.isVerticallyResizable = false
            if let parent = text.superview { text.frame = parent.bounds }
        }
        try await fixture.settle()
        fixture.sample("multiline with native self-resizing disabled and frame restored")
    }

    @MainActor static func resize() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let source = String(repeating: "A large pasted paragraph with ordinary words and punctuation. ", count: 500)
        let messages = [Message(role: .user, text: source)]
        fixture.view.update(messages: messages, jumpRequest: 0, bottomInset: 140)
        try await fixture.settle()
        fixture.sample("resize initially pinned")
        for width: CGFloat in [620, 420, 900] {
            fixture.window.setContentSize(NSSize(width: width, height: 650))
            try await fixture.settle()
            fixture.sample("resize settled")
        }
        fixture.view.contentView.scroll(to: NSPoint(x: 0, y: 2000))
        fixture.view.refresh()
        try await fixture.settle()
        // Independent layout maps the preserved pixel offset back to text. Never
        // inspect the live layoutManager here: that changes its TextKit mode.
        func readingCharacter() -> Int {
            guard let text = texts(fixture.view).first else { return -1 }
            let storage = NSTextStorage(attributedString: LinkedText.attributed(AttributedString(source)))
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: text.bounds.width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let rect = fixture.view.documentView!.convert(text.bounds, from: text)
            let point = NSPoint(x: 0, y: fixture.view.contentView.bounds.minY - rect.minY)
            let glyph = layout.glyphIndex(for: point, in: container)
            return layout.characterIndexForGlyph(at: glyph)
        }
        fixture.sample("reading before width cycle")
        print("  independent top character=\(readingCharacter())")
        for width: CGFloat in [620, 900, 620, 900] {
            fixture.window.setContentSize(NSSize(width: width, height: 650))
            try await fixture.settle()
            fixture.sample("reading width cycle")
            print("  independent top character=\(readingCharacter())")
        }
        fixture.state.jumpToLatest()
        fixture.view.update(messages: messages, jumpRequest: fixture.state.jumpRequest, bottomInset: 320)
        try await fixture.settle()
        fixture.sample("composer inset tall")
        fixture.view.update(messages: messages, jumpRequest: fixture.state.jumpRequest, bottomInset: 100)
        try await fixture.settle()
        fixture.sample("composer inset shrunk")
        // Keep normal selection distinct from explicitly forcing TextKit 1. Asking
        // the live view for layoutManager can itself switch the rendering engine.
        if let text = texts(fixture.view).first {
            text.setSelectedRange(NSRange(location: 2, length: 9))
            fixture.window.makeFirstResponder(text)
            for width: CGFloat in [620, 900] {
                fixture.window.setContentSize(NSSize(width: width, height: 650))
                try await fixture.settle()
                fixture.sample("resize with selected text")
            }
            _ = text.layoutManager
            fixture.state.jumpToLatest()
            fixture.view.update(messages: messages, jumpRequest: fixture.state.jumpRequest, bottomInset: 140)
            try await fixture.settle()
            fixture.window.setContentSize(NSSize(width: 620, height: 650))
            try await fixture.settle()
            fixture.sample("resize after explicitly forcing legacy TextKit")
        }
    }

    @MainActor static func estimates() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let messages = (0..<100).map { _ in Message(role: .user, text: String(repeating: "x\n", count: 300)) }
        fixture.view.update(messages: messages, jumpRequest: 0, bottomInset: 140)
        try await fixture.settle()
        fixture.sample("history initial bottom")
        for index in stride(from: 90, through: 0, by: -10) {
            fixture.view.contentView.scroll(to: NSPoint(x: 0, y: fixture.state.layout.offsets[index]))
            fixture.view.refresh()
            try await fixture.settle()
            fixture.sample("history row \(index)")
        }
    }

    @MainActor static func markdown() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let messages = [Message(role: .assistant, text: String(repeating: "x\n", count: 300))]
        fixture.view.update(messages: messages, jumpRequest: 0, bottomInset: 140)
        print("markdown immediate row height=\(fixture.state.layout.heights[0])")
        try await fixture.settle()
        fixture.sample("markdown parsed")
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        try await longMultiline()
        try await resize()
        try await estimates()
        try await markdown()
    }
}
