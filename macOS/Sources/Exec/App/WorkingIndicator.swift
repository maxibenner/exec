import AppKit
import SwiftUI

/// A tiny field of asynchronous activations, drawn without relaying animation through layout.
struct WorkingIndicator: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> NeuralActivityView { NeuralActivityView() }
    func updateNSView(_ view: NeuralActivityView, context: Context) {
        view.reduceMotion = reduceMotion
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NeuralActivityView, context: Context) -> CGSize? {
        CGSize(width: 40, height: 16)
    }
    static func dismantleNSView(_ view: NeuralActivityView, coordinator: ()) { view.stop() }

    final class NeuralActivityView: NSView {
        var reduceMotion = false {
            didSet {
                guard oldValue != reduceMotion else { return }
                configureTimer()
                needsDisplay = true
            }
        }
        private var timer: Timer?
        private var elapsed: TimeInterval = 0
        private var lastTick: TimeInterval?
        override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 16) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The enclosing button supplies the Stop accessibility action and label.
            setAccessibilityElement(false)
            configureTimer()
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            lastTick = nil
        }

        private func configureTimer() {
            stop()
            guard window != nil, !reduceMotion else { return }
            let timer = Timer(timeInterval: 1.0 / 30, target: self,
                              selector: #selector(tick), userInfo: nil, repeats: true)
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        @objc private func tick() {
            guard window?.occlusionState.contains(.visible) == true else {
                lastTick = nil
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let lastTick { elapsed += min(now - lastTick, 0.1) }
            lastTick = now
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let time = reduceMotion ? 0.8 : elapsed
            for row in 0..<3 {
                for column in 0..<7 {
                    let index = Double(row * 7 + column)
                    // Two drifting waves interfere with individually phased node pulses.
                    // No per-frame randomness: brightness rises and falls continuously.
                    let wave = sin(time * 2.3 - Double(column) * 0.85 + Double(row) * 1.2)
                    let pulse = sin(time * (1.7 + index.truncatingRemainder(dividingBy: 5) * 0.19)
                                    + index * 2.399)
                    let activation = pow(max(0, (wave + pulse) / 2), 2)
                    let center = NSPoint(x: 2 + Double(column) * 6, y: 2 + Double(row) * 6)
                    if activation > 0.1 {
                        NSColor.controlAccentColor.withAlphaComponent(activation * 0.13).setFill()
                        NSBezierPath(ovalIn: NSRect(x: center.x - 2.4, y: center.y - 2.4,
                                                   width: 4.8, height: 4.8)).fill()
                    }
                    NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
                    let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 1.25, y: center.y - 1.25,
                                                        width: 2.5, height: 2.5))
                    dot.fill()
                    NSColor.controlAccentColor.withAlphaComponent(0.15 + activation * 0.85).setFill()
                    dot.fill()
                }
            }
        }
    }
}
