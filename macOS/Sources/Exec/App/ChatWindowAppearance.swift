import AppKit
import SwiftUI

/// Keep native title controls and let the system manage the toolbar boundary.
@MainActor enum ChatWindowAppearance {
    static func configure(_ window: NSWindow?) {
        guard let window else { return }
        if window.titleVisibility != .visible { window.titleVisibility = .visible }
    }
}

/// Keep both SwiftUI scene windows and detached AppKit windows in sync with the
/// conversation catalog, including renames and automatically generated titles.
struct ChatWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) {
        view.title = title
        view.updateTitle()
    }

    final class TitleView: NSView {
        var title = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateTitle()
        }
        func updateTitle() {
            guard let window else { return }
            if window.title != title { window.title = title }
            ChatWindowAppearance.configure(window)
        }
    }
}
