import AppKit
import SwiftUI

struct ComposerControlBounds: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

/// Cursor-only overlay; clicks and text selection pass through to the SwiftUI controls.
struct ComposerCursor: NSViewRepresentable {
    var exclusions: [CGRect]

    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {
        if view.exclusions != exclusions {
            view.exclusions = exclusions
            view.updateTrackingAreas()
        }
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var exclusions: [CGRect] = []
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            for rect in ComposerCursor.regions(in: bounds, excluding: exclusions) {
                addTrackingArea(NSTrackingArea(rect: rect,
                    options: [.activeInKeyWindow, .cursorUpdate, .mouseEnteredAndExited, .mouseMoved],
                    owner: self, userInfo: nil))
            }
        }

        // SwiftUI's hosting view can reset the cursor while crossing its padding.
        // Refresh it on movement as well as entry, without intercepting clicks.
        override func cursorUpdate(with event: NSEvent) { NSCursor.iBeam.set() }
        override func mouseEntered(with event: NSEvent) { NSCursor.iBeam.set() }
        override func mouseMoved(with event: NSEvent) { NSCursor.iBeam.set() }

        override func resetCursorRects() {
            super.resetCursorRects()
            for rect in ComposerCursor.regions(in: bounds, excluding: exclusions) {
                addCursorRect(rect, cursor: .iBeam)
            }
        }
    }

    static func regions(in bounds: CGRect, excluding exclusions: [CGRect]) -> [CGRect] {
        exclusions.reduce([bounds]) { regions, exclusion in
            regions.flatMap { rect -> [CGRect] in
                let cut = rect.intersection(exclusion)
                guard !cut.isNull, !cut.isEmpty else { return [rect] }
                return [
                    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
                    CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
                    CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height)
                ].filter { !$0.isEmpty }
            }
        }
    }
}
