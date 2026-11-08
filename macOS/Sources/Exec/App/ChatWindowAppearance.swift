import AppKit
import SwiftUI

/// Keep native window chrome while presenting workspace information in the composer.
struct ChatWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView { ConfigurationView() }
    func updateNSView(_ view: ConfigurationView, context: Context) { view.configure() }
    static func dismantleNSView(_ view: ConfigurationView, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
    }

    @MainActor static func configure(_ window: NSWindow?) {
        guard let window else { return }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        // The chat toolbar contains navigation controls and layout items only.
        // Keep its controls in the navigation area, outside the normal overflow
        // layout while the sidebar's tracking separator is moving.
        for item in window.toolbar?.items ?? [] where
            item.itemIdentifier != .flexibleSpace && item.itemIdentifier != .space &&
            !(item is NSTrackingSeparatorToolbarItem) && !item.isNavigational {
            item.isNavigational = true
        }
    }

    final class ConfigurationView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                // SwiftUI installs its toolbar after the content view attaches.
                NotificationCenter.default.addObserver(self, selector: #selector(configure),
                    name: NSWindow.didUpdateNotification, object: window)
            }
            configure()
        }
        @objc func configure() { ChatWindowAppearance.configure(window) }
    }
}
