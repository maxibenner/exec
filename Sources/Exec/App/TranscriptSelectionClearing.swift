import AppKit

/// Clear other text selections on a primary click inside this transcript, without
/// consuming the click or interfering with selection/shift-click in its target.
@MainActor final class TranscriptSelectionClearing {
    private weak var transcript: NSView?
    private var monitor: Any?

    init(_ transcript: NSView) {
        self.transcript = transcript
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func handle(_ event: NSEvent) {
        guard monitor != nil, event.type == .leftMouseDown, !event.modifierFlags.contains(.control),
              let transcript, let window = transcript.window,
              event.window === window, let root = window.contentView else { return }
        let point = root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = root.hitTest(point), contains(transcript, hit) else { return }
        clearSelections(in: transcript, except: hit, window: window)
    }

    private func contains(_ view: NSView, _ hit: NSView) -> Bool {
        hit === view || hit.isDescendant(of: view)
    }

    private func clearSelections(in view: NSView, except hit: NSView, window: NSWindow) {
        // SwiftUI selectable Text uses a text field and the window's field editor.
        // Use the public AppKit interfaces, not SwiftUI's private view classes.
        if let field = view as? NSTextField, let editor = field.currentEditor() as? NSTextView {
            if !contains(field, hit), !contains(editor, hit) { clear(editor, window: window) }
            return
        }
        if let text = view as? NSTextView {
            if !contains(text, hit) { clear(text, window: window) }
            return
        }
        for child in view.subviews { clearSelections(in: child, except: hit, window: window) }
    }

    private func clear(_ text: NSTextView, window: NSWindow) {
        if text.selectedRanges.contains(where: { $0.rangeValue.length > 0 }) {
            text.setSelectedRange(NSRange(location: min(text.selectedRange().location, text.string.utf16.count), length: 0))
        }
        if window.firstResponder === text { window.makeFirstResponder(nil) }
    }
}
