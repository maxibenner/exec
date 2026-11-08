import AppKit
import SwiftUI

/// Keep the window fixed when its native sidebar is shown or hidden.
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

        func configure() {
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView,
                   let controller = split.delegate as? NSSplitViewController {
                    for item in controller.splitViewItems where item.behavior == .sidebar && item.collapseBehavior != .useConstraints {
                        // AppKit's default resize heuristic can grow a window
                        // already at its minimum width. Let the split view's
                        // existing constraints resize the chat pane instead.
                        item.collapseBehavior = .useConstraints
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
