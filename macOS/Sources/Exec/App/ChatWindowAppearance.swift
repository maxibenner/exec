import AppKit

/// Keep native window chrome while presenting workspace information in the composer.
@MainActor enum ChatWindowAppearance {
    static func configure(_ window: NSWindow?) {
        window?.titleVisibility = .hidden
    }
}
