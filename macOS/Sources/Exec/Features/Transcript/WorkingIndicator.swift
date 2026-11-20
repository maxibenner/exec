import AppKit
import QuartzCore
import SwiftUI
#if canImport(ExecTranscript)
import ExecTranscript
#endif

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

        private static let duration = NeuralPulse.duration
        private static let curves = NeuralPulse.curves
        private static func brightness(dot: Int, time: Double) -> Float {
            NeuralPulse.brightness(dot: dot, time: time)
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
                // Tool cards use quaternary gray at 25% opacity, but that extra
                // reduction makes a 2.5-point dot nearly invisible. Retain the
                // quaternary gray's full contrast and flatten it over the chat
                // background so the base stays opaque beneath the accent pulse.
                let gray = NSColor.quaternaryLabelColor
                let base = NSColor.textBackgroundColor.blended(
                    withFraction: gray.alphaComponent, of: gray.withAlphaComponent(1))
                    ?? NSColor.windowBackgroundColor
                for dot in baseDots {
                    dot.backgroundColor = base.cgColor
                    dot.opacity = 1
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
