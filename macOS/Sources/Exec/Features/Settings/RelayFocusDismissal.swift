import SwiftUI

/// A window-local click monitor leaves the original event intact, so links and
/// controls still work while clicking empty form space also commits the field.
struct RelayFocusDismissal: NSViewRepresentable {
    var isFocused: Bool
    var dismiss: () -> Void
    func makeNSView(context: Context) -> FocusView { FocusView() }
    func updateNSView(_ view: FocusView, context: Context) {
        view.isFocused = isFocused
        view.dismiss = dismiss
    }
    static func dismantleNSView(_ view: FocusView, coordinator: ()) { view.stop() }

    final class FocusView: NSView {
        var isFocused = false
        var dismiss: (() -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, self.isFocused else { return event }
                if event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    // Let the clicked control handle its action before blur autosaves.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isFocused else { return }
                        self.window?.makeFirstResponder(nil)
                        self.dismiss?()
                    }
                }
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
