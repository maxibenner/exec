import AppKit
import SwiftUI

/// Use the native title bar and its standard hairline for every chat window.
@MainActor enum ChatWindowAppearance {
    static func configure(_ window: NSWindow?) {
        guard let window else { return }
        if window.titleVisibility != .visible { window.titleVisibility = .visible }
        let separator: NSTitlebarSeparatorStyle = window.title.isEmpty ? .none : .line
        if window.titlebarSeparatorStyle != separator { window.titlebarSeparatorStyle = separator }
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
