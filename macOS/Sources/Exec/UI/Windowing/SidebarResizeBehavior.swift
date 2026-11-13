import AppKit
import SwiftUI

/// Keep the window fixed when its native sidebar is shown or hidden, and route
/// ⌘S through that same native toggle action without replacing its toolbar item.
struct SidebarResizeBehavior: NSViewRepresentable {
    let initiallyShowsSidebar: Bool
    let revealRequest: Int

    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView(initiallyShowsSidebar: initiallyShowsSidebar, revealRequest: revealRequest)
    }
    func updateNSView(_ view: ConfigurationView, context: Context) {
        view.revealRequest = revealRequest
        view.configure()
    }

    final class ConfigurationView: NSView {
        private let initiallyShowsSidebar: Bool
        var revealRequest: Int
        private weak var configuredController: NSSplitViewController?
        private var appliedRevealRequest: Int?

        init(initiallyShowsSidebar: Bool, revealRequest: Int) {
            self.initiallyShowsSidebar = initiallyShowsSidebar
            self.revealRequest = revealRequest
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
            guard let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) else { return }
            if configuredController !== controller {
                configuredController = controller
                appliedRevealRequest = revealRequest
                sidebar.isCollapsed = !(initiallyShowsSidebar || revealRequest > 0)
            } else if appliedRevealRequest != revealRequest {
                // One-shot commands, never a visibility value replayed on every
                // presentation update. Native toggles remain authoritative.
                appliedRevealRequest = revealRequest
                sidebar.animator().isCollapsed = false
            }
        }
    }
}
