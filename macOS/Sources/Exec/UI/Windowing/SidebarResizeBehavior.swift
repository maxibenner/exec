import AppKit
import SwiftUI

/// Keep the window fixed when its native sidebar is shown or hidden, and route
/// ⌘S through that same native toggle action without replacing its toolbar item.
struct SidebarResizeBehavior: NSViewRepresentable {
    var onVisibilityChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> ConfigurationView {
        let view = ConfigurationView(frame: .zero)
        view.onVisibilityChange = onVisibilityChange
        return view
    }
    func updateNSView(_ view: ConfigurationView, context: Context) {
        view.onVisibilityChange = onVisibilityChange
        view.configure()
    }

    static func dismantleNSView(_ view: ConfigurationView, coordinator: ()) {
        view.stopObserving()
        view.onVisibilityChange = { _ in }
    }

    final class ConfigurationView: NSView {
        var onVisibilityChange: (Bool) -> Void = { _ in }
        private weak var observedItem: NSSplitViewItem?
        private var collapseObservation: NSKeyValueObservation?
        private var observationID: UUID?
        private var lastVisibility: Bool?

        func stopObserving() {
            collapseObservation = nil
            observedItem = nil
            observationID = nil
            lastVisibility = nil
        }

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
            guard window != nil, let controller = splitController,
                  let item = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) else {
                stopObserving()
                return
            }
            if observedItem !== item {
                stopObserving()
                observedItem = item
                lastVisibility = !item.isCollapsed
                // Native menu/keyboard toggles do not always update SwiftUI's
                // binding. Do not infer a startup preference. Scope queued work
                // to this attachment, even if the same split item is reattached.
                let identity = UUID()
                observationID = identity
                collapseObservation = item.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.window != nil, self.observationID == identity,
                              let item = self.observedItem else { return }
                        let visible = !item.isCollapsed
                        guard self.lastVisibility != visible else { return }
                        self.lastVisibility = visible
                        self.onVisibilityChange(visible)
                    }
                }
            }
            for item in controller.splitViewItems where item.behavior == .sidebar && item.collapseBehavior != .useConstraints {
                // AppKit's default resize heuristic can grow a window
                // already at its minimum width. Let the split view's
                // existing constraints resize the chat pane instead.
                item.collapseBehavior = .useConstraints
            }
        }
    }
}
