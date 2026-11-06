import AppKit
import SwiftUI

/// Keep the settings toolbar boundary stable as the tabs' scroll views change.
struct SettingsWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }

    func updateNSView(_ view: WindowView, context: Context) {
        view.window?.titlebarSeparatorStyle = .none
    }

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Automatic separators can appear briefly as grouped forms attach
            // or scroll beneath the settings toolbar.
            window?.titlebarSeparatorStyle = .none
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
