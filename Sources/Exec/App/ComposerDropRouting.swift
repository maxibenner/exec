import AppKit
import SwiftUI

/// Leaves drag handling to the composer's SwiftUI drop destination, rather than
/// letting AppKit's text field or shared field editor insert a file's path.
struct ComposerDropRouting: NSViewRepresentable {
    func makeNSView(context: Context) -> RoutingView { RoutingView() }
    func updateNSView(_ view: RoutingView, context: Context) { view.scheduleUpdate() }
    static func dismantleNSView(_ view: RoutingView, coordinator: ()) { view.stop() }

    final class RoutingView: NSView {
        private var registrations: [(view: NSView, types: [NSPasteboard.PasteboardType])] = []
        private var observers: [NSObjectProtocol] = []
        private var scheduled = false
        private var stopped = false

        func stop() {
            stopped = true
            restore()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            restore()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            guard window != nil else { return }
            for name in [NSControl.textDidBeginEditingNotification, NSText.didBeginEditingNotification,
                         NSControl.textDidEndEditingNotification, NSText.didEndEditingNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleUpdate() }
                })
            }
            scheduleUpdate()
        }

        isolated deinit {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
        }

        override func layout() {
            super.layout()
            scheduleUpdate()
        }

        func scheduleUpdate() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.updateRouting()
            }
        }

        func restore() {
            for registration in registrations {
                registration.view.registerForDraggedTypes(registration.types)
            }
            registrations.removeAll()
        }

        func updateRouting() {
            restore()
            guard !stopped, let window, let root = window.contentView else { return }
            // Match only native text controls overlapping this field; SwiftUI's
            // hosting views retain their own drop registrations.
            let area = convert(bounds, to: nil)
            func visit(_ view: NSView) {
                guard view !== self, !view.isHidden,
                      view.convert(view.bounds, to: nil).intersects(area) else { return }
                if view is NSTextField || view is NSTextView {
                    let types = view.registeredDraggedTypes
                    if !types.isEmpty {
                        registrations.append((view, types))
                        view.unregisterDraggedTypes()
                    }
                }
                for child in view.subviews { visit(child) }
            }
            visit(root)
            // The shared field editor can live outside the text field's subtree.
            if let editor = window.firstResponder as? NSTextView,
               !registrations.contains(where: { $0.view === editor }),
               editor.convert(editor.bounds, to: nil).intersects(area) {
                let types = editor.registeredDraggedTypes
                if !types.isEmpty {
                    registrations.append((editor, types))
                    editor.unregisterDraggedTypes()
                }
            }
        }
    }
}
