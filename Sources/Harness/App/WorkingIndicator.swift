import AppKit
import SwiftUI

/// The eight-cell, fourteen-frame bounce from pi-config's personal footer.
enum WorkingFrames {
    static func frame(_ step: Int) -> [Character] {
        let step = step % 14
        let head = step < 8 ? step : 14 - step
        let direction = step < 8 ? 1 : -1
        let trail: [Character] = ["█", "▓", "▒", "░"]
        return (0..<8).map { index in
            let distance = (head - index) * direction
            return trail.indices.contains(distance) ? trail[distance] : "·"
        }
    }
}

/// Redraw a fixed-size native view: animation never invalidates SwiftUI layout.
struct WorkingIndicator: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> IndicatorView { IndicatorView() }
    func updateNSView(_ view: IndicatorView, context: Context) { view.reduceMotion = reduceMotion }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: IndicatorView, context: Context) -> CGSize? {
        CGSize(width: 64, height: 16)
    }
    static func dismantleNSView(_ view: IndicatorView, coordinator: ()) { view.stop() }

    final class IndicatorView: NSView {
        var reduceMotion = false {
            didSet { if oldValue != reduceMotion { configureTimer(); needsDisplay = true } }
        }
        private var timer: Timer?
        private var step = 0
        override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 16) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setAccessibilityElement(false)
            configureTimer()
        }

        func stop() { timer?.invalidate(); timer = nil }
        private func configureTimer() {
            stop()
            guard window != nil, !reduceMotion else { return }
            let timer = Timer(timeInterval: 0.08, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        @objc private func tick() {
            guard window?.occlusionState.contains(.visible) == true else { return }
            step = (step + 1) % 14
            needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            for (index, character) in WorkingFrames.frame(reduceMotion ? 0 : step).enumerated() {
                let color: NSColor
                switch character {
                case "█", "▓": color = .controlAccentColor
                case "▒": color = .secondaryLabelColor
                default: color = .tertiaryLabelColor
                }
                (String(character) as NSString).draw(at: NSPoint(x: CGFloat(index) * 8, y: 1),
                    withAttributes: [.font: font, .foregroundColor: color])
            }
        }
    }
}
