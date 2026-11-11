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
        nsView.intrinsicContentSize
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
        override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 16) }

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
            WorkingIndicatorProbe.tick()
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
            let probeStart = WorkingIndicatorProbe.beginDraw()
            defer { WorkingIndicatorProbe.endDraw(probeStart) }
            let time = (reduceMotion ? 0.8 : elapsed) * 1.5
            for row in 0..<3 {
                for column in 0..<5 {
                    // Retain the original seven-column phases for the remaining dots.
                    let index = Double(row * 7 + column)
                    // Independently phased pulses, without a travelling spatial wave.
                    // Match variation 5 in the preview; brightness changes continuously.
                    let phase = index * 2.399
                    let pulse = sin(time * (1.7 + index.truncatingRemainder(dividingBy: 5) * 0.19)
                                    + phase)
                    let value = pulse * 0.75 + sin(time * 0.7 + phase * 1.3) * 0.25
                    // A small positive bias recruits a few more dots into each cluster.
                    let activation = pow(max(0, value + 0.1), 2)
                    let center = NSPoint(x: 2 + Double(column) * 6, y: 2 + Double(row) * 6)
                    // Match the tool cards' quaternary background at 25% opacity.
                    let base = NSColor.quaternaryLabelColor
                    base.withAlphaComponent(base.alphaComponent * 0.25).setFill()
                    let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 1.25, y: center.y - 1.25,
                                                        width: 2.5, height: 2.5))
                    dot.fill()
                    // Reach the original scanner's full accent color, with no blue tint at rest.
                    NSColor.controlAccentColor.withAlphaComponent(min(1, activation * 2.5)).setFill()
                    dot.fill()
                }
            }
        }
    }
}
