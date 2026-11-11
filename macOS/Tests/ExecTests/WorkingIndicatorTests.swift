import AppKit
import QuartzCore

@MainActor struct WorkingIndicatorTests {
    // Unit tests control visibility without depending on desktop focus/occlusion.
    // The standalone benchmark verifies real presentation-layer motion onscreen.
    private final class TestWindow: NSWindow {
        var visibleForTest = true
        override var occlusionState: NSWindow.OcclusionState {
            visibleForTest ? [.visible] : []
        }
        func setVisibleForTest(_ visible: Bool) {
            visibleForTest = visible
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self)
        }
    }

    func layerAnimationLifecycle() throws {
        _ = NSApplication.shared
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
                                styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let view = WorkingIndicator.NeuralActivityView(frame: NSRect(x: 20, y: 20, width: 28, height: 16))
        container.addSubview(view)
        window.contentView = container
        defer { view.stop(); window.close() }
        try expect(view.isAnimating)
        let dots = view.layer?.sublayers?.filter { $0.animation(forKey: "neuralPulse") != nil } ?? []
        try expect(dots.count == 15)
        for dot in dots {
            guard let animation = dot.animation(forKey: "neuralPulse") as? CAKeyframeAnimation,
                  let values = animation.values as? [NSNumber], !values.isEmpty else {
                throw CheckFailure(description: "Missing indicator opacity curve")
            }
            try expect(animation.repeatCount == .infinity)
            try expect(abs(values.first!.doubleValue - values.last!.doubleValue) < 0.00001)
            try expect(values.allSatisfy { (0...1).contains($0.doubleValue) })
            try expect(values.contains { $0.doubleValue > 0.9 } && values.contains { $0.doubleValue == 0 })
        }
        view.reduceMotion = true
        try expect(!view.isAnimating && dots.allSatisfy { $0.animation(forKey: "neuralPulse") == nil })
        let frozen = dots.map(\.opacity)
        window.setVisibleForTest(false)
        window.setVisibleForTest(true)
        try expect(!view.isAnimating && dots.map(\.opacity) == frozen)
        view.reduceMotion = false
        try expect(view.isAnimating)
        window.setVisibleForTest(false)
        try expect(!view.isAnimating)
        window.setVisibleForTest(true)
        try expect(view.isAnimating)
        view.isHidden = true
        try expect(!view.isAnimating)
        view.isHidden = false
        try expect(view.isAnimating)
        view.removeFromSuperview()
        try expect(!view.isAnimating && dots.allSatisfy { $0.animation(forKey: "neuralPulse") == nil })
    }
}
