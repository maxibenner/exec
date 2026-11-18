import AppKit
import SwiftUI

/// Use one native toolbar across both columns, without a window title or collapsible sidebar.
struct SettingsWindowConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView { ConfigurationView(frame: .zero) }
    func updateNSView(_ view: ConfigurationView, context: Context) { view.configure() }

    final class ConfigurationView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); configure() }
        override func layout() { super.layout(); configure() }

        func configure() {
            if let window {
                if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
                // SwiftUI drops an empty toolbar. Keep the sidebar's native header
                // height without inserting a placeholder control in the detail pane.
                if window.toolbar == nil {
                    let toolbar = NSToolbar(identifier: "ExecSettings")
                    toolbar.allowsUserCustomization = false
                    window.toolbar = toolbar
                }
                if window.toolbarStyle != .unified { window.toolbarStyle = .unified }
                if !window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.insert(.fullSizeContentView)
                }
                if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            }
            // SwiftUI can attach the split controller after the initial move callback.
            var ancestor = superview
            while let view = ancestor {
                if let split = view as? NSSplitView,
                   let controller = split.delegate as? NSSplitViewController {
                    for item in controller.splitViewItems where item.behavior == .sidebar {
                        if item.canCollapse { item.canCollapse = false }
                        if item.isCollapsed { item.isCollapsed = false }
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}
