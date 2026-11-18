import AppKit
import SwiftUI

@MainActor
struct ComposerTextInputTests {
    @Observable final class Model {
        var text = ""
        var focused = false
        var placeholder = "Message"
    }

    private struct Host: View {
        @Bindable var model: Model
        var body: some View {
            ComposerTextInput(text: $model.text, focused: $model.focused,
                              session: ObjectIdentifier(model), enabled: true, placeholder: model.placeholder,
                              onSubmit: {}, onMove: { _ in false }, onEscape: {})
                .frame(width: 400).fixedSize(horizontal: false, vertical: true)
        }
    }

    func bridgesFocusAndPreservesComposition() async throws {
        _ = NSApplication.shared
        let model = Model()
        let host = NSHostingView(rootView: Host(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        func findEditor(in view: NSView) -> ComposerTextInput.EditorScrollView? {
            if let editor = view as? ComposerTextInput.EditorScrollView { return editor }
            return view.subviews.lazy.compactMap { findEditor(in: $0) }.first
        }
        guard let view = findEditor(in: host) else { throw CheckFailure(description: "Composer editor not mounted") }
        // Native mouse/keyboard focus must update the state used by the palette
        // and border; background clicks must be able to request focus in turn.
        try expect(window.makeFirstResponder(view.editor))
        try await settle()
        try expect(model.focused)
        try expect(window.makeFirstResponder(host))
        try await settle()
        try expect(!model.focused)
        model.focused = true
        try await settle()
        try expect(window.firstResponder === view.editor)
        let oneLine = host.fittingSize.height
        model.text = String(repeating: "line\n", count: 30)
        try await settle()
        host.layoutSubtreeIfNeeded()
        try expect(host.fittingSize.height > oneLine && host.fittingSize.height <= oneLine * 8)
        model.text = ""
        try await settle()
        view.editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                                  replacementRange: NSRange(location: 0, length: 0))
        model.placeholder = "Changed while composing"
        try await settle()
        try expect(view.editor.hasMarkedText() && view.editor.string == "かな")
        // A genuine external replacement still wins over provisional input.
        model.text = "replacement"
        try await settle()
        try expect(view.editor.string == "replacement")
        model.focused = false
        try await settle()
        try expect(window.firstResponder !== view.editor)
    }

    func preservesViewportAcrossFocusChanges() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: window.contentLayoutRect)
        let view = ComposerTextInput.EditorScrollView()
        view.frame = NSRect(x: 20, y: 20, width: 500, height: 120)
        root.addSubview(view)
        let other = NSTextField(string: "Another field")
        other.frame = NSRect(x: 20, y: 200, width: 300, height: 24)
        root.addSubview(other)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        let session = NSObject()
        let draft = (1...40).map { "Line \($0): a long composer draft" }.joined(separator: "\n")
        view.update(text: draft, session: ObjectIdentifier(session), request: 1, enabled: true, focused: true)
        try await settle()
        try expect(window.firstResponder === view.editor)
        view.editor.setSelectedRange(NSRange(location: draft.utf16.count, length: 0))
        view.editor.scrollRangeToVisible(view.editor.selectedRange())
        try await settle()
        let bottom = view.contentView.bounds.origin
        try expect(bottom.y > 0)

        // Include manually scrolling away from the caret, not just following it.
        for origin in [bottom, NSPoint(x: 0, y: bottom.y / 2)] {
            view.contentView.scroll(to: origin)
            view.reflectScrolledClipView(view.contentView)
            let selection = view.editor.selectedRange()
            try expect(window.makeFirstResponder(other))
            try await settle()
            try expect(view.contentView.bounds.origin == origin)
            // Unrelated SwiftUI updates must not replace the draft or viewport.
            view.update(text: draft, session: ObjectIdentifier(session), request: 1, enabled: true, focused: false)
            try expect(window.makeFirstResponder(view.editor))
            try await settle()
            try expect(view.contentView.bounds.origin == origin)
            try expect(view.editor.selectedRange() == selection)
            view.update(text: draft, session: ObjectIdentifier(session), request: 2, enabled: true, focused: true)
            try await settle()
            try expect(view.contentView.bounds.origin == origin && view.editor.selectedRange() == selection)
        }
        view.update(text: "", session: ObjectIdentifier(session), request: 2, enabled: true, focused: true)
        try await settle()
        try expect(view.editor.string.isEmpty && view.contentView.bounds.origin == .zero)
        try expect(view.editor.selectedRange() == NSRange(location: 0, length: 0))
        // Field-style Tab traversal must not insert a literal tab in the draft.
        view.editor.nextKeyView = other
        view.editor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        try expect(window.firstResponder === other.currentEditor())
        try expect(view.editor.string.isEmpty)
    }

    func sizesAndRoutesEditingCommands() throws {
        _ = NSApplication.shared
        let view = ComposerTextInput.EditorScrollView()
        let session = NSObject()
        func setText(_ text: String) {
            view.update(text: text, session: ObjectIdentifier(session), request: nil, enabled: true, focused: false)
        }
        setText("")
        let oneLine = view.height(for: 400)
        setText("one\ntwo")
        try expect(view.height(for: 400) > oneLine)
        setText(String(repeating: "line\n", count: 40))
        let maximum = view.height(for: 400)
        try expect(maximum <= oneLine * 8 && maximum > oneLine * 7)
        setText(String(repeating: "wrapped text ", count: 8))
        try expect(view.height(for: 140) > view.height(for: 600))

        var submitted = 0
        var escaped = 0
        var moves: [Int] = []
        var changed = ""
        view.onSubmit = { submitted += 1 }
        view.onEscape = { escaped += 1 }
        view.onMove = { moves.append($0); return true }
        view.onChange = { changed = $0 }
        try expect(view.textView(view.editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try expect(submitted == 1)
        try expect(!view.textView(view.editor, doCommandBy: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))))
        try expect(view.textView(view.editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        try expect(view.textView(view.editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        try expect(moves == [-1, 1])
        view.onMove = { _ in false }
        try expect(!view.textView(view.editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        try expect(view.textView(view.editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        try expect(escaped == 1)
        setText("")
        view.editor.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        try expect(changed == "hello")
        view.editor.setMarkedText("composing", selectedRange: NSRange(location: 9, length: 0),
                                  replacementRange: NSRange(location: 0, length: 5))
        try expect(!view.textView(view.editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try expect(submitted == 1)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }
}
