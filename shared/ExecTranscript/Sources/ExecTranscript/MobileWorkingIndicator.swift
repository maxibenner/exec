#if canImport(UIKit)
import SwiftUI
import UIKit

public struct MobileWorkingIndicator: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let tintColor: UIColor?
    /// Set a concrete UIKit tint when the transcript must ignore system accents.
    public init(tintColor: UIColor? = nil) { self.tintColor = tintColor }
    public func makeUIView(context: Context) -> NeuralActivityView { NeuralActivityView() }
    public func updateUIView(_ view: NeuralActivityView, context: Context) {
        view.tintColor = tintColor
        view.reduceMotion = reduceMotion
    }
    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: NeuralActivityView, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }
    public static func dismantleUIView(_ view: NeuralActivityView, coordinator: ()) { view.stop() }

    public final class NeuralActivityView: UIView {
        var reduceMotion = false { didSet { if oldValue != reduceMotion { updateAnimations() } } }
        private var baseDots: [CALayer] = []
        private var activeDots: [CALayer] = []
        private var animating = false
        public override var intrinsicContentSize: CGSize { CGSize(width: 28, height: 16) }

        public override init(frame: CGRect) {
            super.init(frame: frame)
            for row in 0..<3 {
                for column in 0..<5 {
                    let base = CALayer(), active = CALayer()
                    for dot in [base, active] {
                        dot.frame = CGRect(x: 0.75 + Double(column) * 6, y: 0.75 + Double(row) * 6, width: 2.5, height: 2.5)
                        dot.cornerRadius = 1.25
                        layer.addSublayer(dot)
                    }
                    baseDots.append(base); activeDots.append(active)
                }
            }
            isAccessibilityElement = true
            accessibilityLabel = "Thinking"
            NotificationCenter.default.addObserver(self, selector: #selector(updateAnimations), name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(updateAnimations), name: UIApplication.didBecomeActiveNotification, object: nil)
            registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (view: NeuralActivityView, _: UITraitCollection) in
                view.updateColors()
            }
            updateColors()
        }
        required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
        public override func didMoveToWindow() {
            super.didMoveToWindow()
            updateColors(); updateAnimations()
        }
        public override func tintColorDidChange() { super.tintColorDidChange(); updateColors() }
        private func updateColors() {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for dot in baseDots { dot.backgroundColor = UIColor.quaternaryLabel.resolvedColor(with: traitCollection).cgColor }
            for dot in activeDots { dot.backgroundColor = tintColor.resolvedColor(with: traitCollection).cgColor }
            for dot in baseDots + activeDots { dot.contentsScale = traitCollection.displayScale }
            CATransaction.commit()
        }
        func stop() {
            for dot in activeDots { dot.removeAnimation(forKey: "neuralPulse") }
            animating = false
        }
        @objc private func updateAnimations() {
            let shouldAnimate = !reduceMotion && window != nil && UIApplication.shared.applicationState == .active
            if !shouldAnimate { stop() }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for (index, dot) in activeDots.enumerated() {
                dot.opacity = NeuralPulse.brightness(dot: index, time: reduceMotion ? 0.8 : 0)
            }
            CATransaction.commit()
            guard shouldAnimate, !animating else { return }
            let curves = NeuralPulse.curves
            let begin = CACurrentMediaTime()
            for (index, dot) in activeDots.enumerated() {
                let animation = CAKeyframeAnimation(keyPath: "opacity")
                animation.values = curves[index]; animation.duration = NeuralPulse.duration
                animation.calculationMode = .linear; animation.repeatCount = .infinity
                animation.beginTime = dot.convertTime(begin, from: nil)
                dot.add(animation, forKey: "neuralPulse")
            }
            animating = true
        }
    }
}
#endif
