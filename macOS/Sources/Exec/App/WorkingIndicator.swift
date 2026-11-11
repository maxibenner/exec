import AppKit
import QuartzCore
import SwiftUI

/// Independent neuron pulses played by Core Animation, without a per-frame app timer.
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
                updateAnimations()
            }
        }
        private var baseDots: [CALayer] = []
        private var activeDots: [CALayer] = []
        private(set) var isAnimating = false
        override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 16) }

        // All pulse frequencies are multiples of 0.01, at 1.5× speed. Their common
        // period preserves the exact independent-neuron pattern without a loop seam.
        private static let duration = 2 * Double.pi / (0.01 * 1.5)
        private static let curves: [[NSNumber]] = {
            let samples = Int(ceil(duration * 30))
            return (0..<15).map { dot in
                (0...samples).map { sample in
                    NSNumber(value: brightness(dot: dot, time: duration * Double(sample) / Double(samples)))
                }
            }
        }()

        private static func brightness(dot: Int, time: Double) -> Float {
            let index = Double((dot / 5) * 7 + dot % 5)
            let phase = index * 2.399
            let time = time * 1.5
            let pulse = sin(time * (1.7 + index.truncatingRemainder(dividingBy: 5) * 0.19) + phase)
            let value = pulse * 0.75 + sin(time * 0.7 + phase * 1.3) * 0.25
            return Float(min(1, pow(max(0, value + 0.1), 2) * 2.5))
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            for row in 0..<3 {
                for column in 0..<5 {
                    let frame = CGRect(x: 0.75 + Double(column) * 6, y: 0.75 + Double(row) * 6,
                                       width: 2.5, height: 2.5)
                    let base = CALayer()
                    let active = CALayer()
                    for dot in [base, active] {
                        dot.frame = frame
                        dot.cornerRadius = 1.25
                        layer?.addSublayer(dot)
                    }
                    baseDots.append(base)
                    activeDots.append(active)
                }
            }
            setAccessibilityElement(false)
            NotificationCenter.default.addObserver(self, selector: #selector(colorsChanged),
                name: NSColor.systemColorsDidChangeNotification, object: nil)
            updateColors()
            updateAnimations()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
                    name: NSWindow.didChangeOcclusionStateNotification, object: window)
            }
            updateColors()
            updateAnimations()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColors()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateColors()
        }

        private func updateColors() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let base = NSColor.quaternaryLabelColor
                for dot in baseDots {
                    dot.backgroundColor = base.withAlphaComponent(base.alphaComponent * 0.25).cgColor
                }
                for dot in activeDots { dot.backgroundColor = NSColor.controlAccentColor.cgColor }
            }
            for dot in baseDots + activeDots { dot.contentsScale = window?.backingScaleFactor ?? 2 }
            CATransaction.commit()
        }

        @objc private func colorsChanged() { updateColors() }
        @objc private func visibilityChanged() { updateAnimations() }

        func stop() {
            for dot in activeDots { dot.removeAnimation(forKey: "neuralPulse") }
            if isAnimating { WorkingIndicatorProbe.animationsStopped(activeDots.count) }
            isAnimating = false
        }

        override func viewDidHide() {
            super.viewDidHide()
            updateAnimations()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            updateAnimations()
        }

        private func updateAnimations() {
            let shouldAnimate = !reduceMotion && !isHiddenOrHasHiddenAncestor
                && window?.occlusionState.contains(.visible) == true
            if !shouldAnimate { stop() }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (index, dot) in activeDots.enumerated() {
                dot.opacity = Self.brightness(dot: index, time: reduceMotion ? 0.8 : 0)
            }
            CATransaction.commit()
            guard shouldAnimate, !isAnimating else { return }
            // Build once per process, not per frame or per conversation.
            let curves = Self.curves
            let begin = CACurrentMediaTime()
            for (index, dot) in activeDots.enumerated() {
                let animation = CAKeyframeAnimation(keyPath: "opacity")
                animation.values = curves[index]
                animation.duration = Self.duration
                animation.calculationMode = .linear
                animation.repeatCount = .infinity
                animation.beginTime = dot.convertTime(begin, from: nil)
                dot.add(animation, forKey: "neuralPulse")
            }
            isAnimating = true
            WorkingIndicatorProbe.animationsStarted(activeDots.count)
        }
    }
}
