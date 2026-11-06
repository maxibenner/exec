import AppKit
import SwiftUI

@MainActor struct TranscriptSelectionTests {
    func clearsOtherSelectionsWithoutStealingClicks() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = root
        let transcript = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        root.addSubview(transcript)
        func text(at y: CGFloat) -> LinkedText.TextView {
            let view = LinkedText.TextView(frame: NSRect(x: 20, y: y, width: 300, height: 80))
            view.isEditable = false
            view.isSelectable = true
            view.string = "Selectable reply text"
            transcript.addSubview(view)
            return view
        }
        let first = text(at: 20)
        let second = text(at: 120)
        let clearing = TranscriptSelectionClearing(transcript)
        defer { clearing.stop(); window.contentView = nil }
        func click(_ point: NSPoint, type: NSEvent.EventType = .leftMouseDown,
                   modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let selected = NSRange(location: 0, length: 10)
        first.setSelectedRange(selected)
        second.setSelectedRange(selected)
        // Preserve the clicked view's range for AppKit to handle shift-click normally.
        clearing.handle(click(NSPoint(x: 40, y: 40), modifiers: .shift))
        try expect(first.selectedRange() == selected && second.selectedRange().length == 0)
        clearing.handle(click(NSPoint(x: 500, y: 400)))
        try expect(first.selectedRange().length == 0)

        first.setSelectedRange(selected)
        clearing.handle(click(NSPoint(x: 500, y: 400), type: .rightMouseDown))
        clearing.handle(click(NSPoint(x: 500, y: 400), modifiers: .control))
        clearing.handle(click(NSPoint(x: 700, y: 400))) // Sidebar / composer outside the transcript.
        let otherWindow = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let foreign = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 500, y: 400),
                                        modifierFlags: [], timestamp: 0, windowNumber: otherWindow.windowNumber,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        clearing.handle(foreign)
        try expect(first.selectedRange() == selected)
        let overlay = NSView(frame: transcript.frame)
        root.addSubview(overlay)
        clearing.handle(click(NSPoint(x: 40, y: 40)))
        try expect(first.selectedRange() == selected) // Overlapping approval panels are not chat clicks.
        overlay.removeFromSuperview()

        // A button still receives the original click; clearing doesn't consume events.
        let button = NSButton(title: "Tool disclosure", target: nil, action: nil)
        button.frame = NSRect(x: 20, y: 230, width: 200, height: 30)
        transcript.addSubview(button)
        clearing.handle(click(NSPoint(x: 40, y: 245)))
        try expect(first.selectedRange().length == 0)

        // Exercise the same native text component used by expanded tool inputs/output.
        let host = NSHostingView(rootView: ToolTextSection(title: nil, text: "Selectable tool output")
            .frame(width: 300, height: 80))
        host.frame = NSRect(x: 20, y: 300, width: 300, height: 80)
        transcript.addSubview(host)
        host.layoutSubtreeIfNeeded()
        func textViews(in view: NSView) -> [NSTextView] {
            if let text = view as? NSTextView { return [text] }
            return view.subviews.flatMap { textViews(in: $0) }
        }
        guard let editor = textViews(in: host).first else {
            throw CheckFailure(description: "Expected selectable native tool text")
        }
        try expect(editor.isSelectable && !editor.isEditable)
        try expect(editor.string == "Selectable tool output")
        editor.setSelectedRange(selected)
        first.setSelectedRange(selected)
        let textPoint = editor.convert(NSPoint(x: editor.bounds.midX, y: editor.bounds.midY), to: nil)
        clearing.handle(click(textPoint, modifiers: .shift))
        try expect(editor.selectedRange() == selected && first.selectedRange().length == 0)
        clearing.handle(click(NSPoint(x: 500, y: 400)))
        try expect(editor.selectedRange().length == 0)
        try expect(window.firstResponder !== editor)
        editor.setSelectedRange(selected)
        clearing.handle(click(NSPoint(x: 40, y: 245))) // Nonselectable tool disclosure header.
        try expect(editor.selectedRange().length == 0)

        first.setSelectedRange(selected)
        clearing.stop()
        clearing.handle(click(NSPoint(x: 500, y: 400)))
        try expect(first.selectedRange() == selected)
    }
}
