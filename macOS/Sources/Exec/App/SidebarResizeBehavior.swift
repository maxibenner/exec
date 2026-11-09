import AppKit
import SwiftUI

/// Keep the window fixed when its native sidebar is shown or hidden, and route
/// ⌘S through that same native toggle action without replacing its toolbar item.
struct SidebarResizeBehavior: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView { ConfigurationView() }
    func updateNSView(_ view: ConfigurationView, context: Context) { view.configure() }

    final class ConfigurationView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        // SwiftUI can attach the containing hierarchy after the representable
        // receives its move callbacks. Resolve the split controller at layout too,
        // before AppKit chooses how to animate the first sidebar expansion.
        override func layout() { super.layout(); configure() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.type == .keyDown,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "s",
                  let controller = splitController else {
                return super.performKeyEquivalent(with: event)
            }
            // Use the same animated action as the native toolbar button, rather
            // than assigning SwiftUI column visibility or adding another button.
            controller.toggleSidebar(nil)
            return true
        }

        private var splitController: NSSplitViewController? {
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView,
                   let controller = split.delegate as? NSSplitViewController {
                    return controller
                }
                ancestor = view.superview
            }
            return nil
        }

        func configure() {
            guard let controller = splitController else { return }
            for item in controller.splitViewItems where item.behavior == .sidebar && item.collapseBehavior != .useConstraints {
                // AppKit's default resize heuristic can grow a window
                // already at its minimum width. Let the split view's
                // existing constraints resize the chat pane instead.
                item.collapseBehavior = .useConstraints
            }
        }
    }
}
