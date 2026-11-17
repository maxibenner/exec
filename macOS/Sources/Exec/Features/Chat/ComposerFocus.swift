import AppKit
import SwiftUI

/// A one-shot responder request attached to the composer's actual text field.
/// Unlike toggling FocusState across Task.yield(), this cannot be coalesced into
/// an unchanged `true` value, and it waits for the native field to be mounted and
/// enabled rather than guessing how long navigation/layout will take.
struct ComposerFocus: NSViewRepresentable {
    let request: Int?
    let enabled: Bool

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.update(request: request, enabled: enabled) }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.update(request: nil, enabled: false) }

    final class Anchor: NSView {
        private var request: Int?
        private var enabled = false
        private var pending = false
        private var scheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        override func layout() { super.layout(); schedule() }

        func update(request: Int?, enabled: Bool) {
            // Reorder/rename navigation can disable the same editor without a
            // new session or request ID. Restore focus when that field is ready.
            if self.request != request || (enabled && !self.enabled) {
                pending = request != nil
            }
            self.request = request
            self.enabled = enabled
            schedule()
        }
        private func schedule() {
            guard pending, enabled, window != nil, !scheduled else { return }
            scheduled = true
            // Leave SwiftUI's update transaction. This is a single commit-bound
            // handoff, not a timer/retry loop; mount/layout also drive readiness.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.focusIfReady()
            }
        }
        private func focusIfReady() {
            guard pending, enabled, let window, !isHiddenOrHasHiddenAncestor,
                  let field = textField() else { return }
            pending = false
            // Repeated requests must not reset the selection in an active editor.
            if let editor = field.currentEditor(), window.firstResponder === editor { return }
            if !window.makeFirstResponder(field) { pending = true }
        }
        private func textField() -> NSTextField? {
            func fields(in view: NSView) -> [NSTextField] {
                if let field = view as? NSTextField { return [field] }
                return view.subviews.flatMap { fields(in: $0) }
            }
            // The background and the AppKit TextField are siblings under SwiftUI
            // hosting views. Match only the field overlapping this local anchor,
            // never an arbitrary editor elsewhere in this or another window.
            let rect = convert(bounds, to: nil)
            guard !rect.isEmpty else { return nil }
            var ancestor = superview
            while let view = ancestor {
                if let field = fields(in: view).first(where: {
                    $0.isEnabled && $0.isEditable && !$0.isHiddenOrHasHiddenAncestor &&
                        $0.convert($0.bounds, to: nil).intersects(rect)
                }) { return field }
                ancestor = view.superview
            }
            return nil
        }
    }
}
