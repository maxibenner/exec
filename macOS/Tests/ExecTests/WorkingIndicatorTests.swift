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

    func grayBasesRemainVisibleUnderBluePulses() throws {
        _ = NSApplication.shared
        let view = WorkingIndicator.NeuralActivityView(frame: NSRect(x: 0, y: 0, width: 28, height: 16))
        view.reduceMotion = true
        defer { view.stop() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: appearance)
            view.viewDidChangeEffectiveAppearance()
            guard let root = view.layer, let layers = root.sublayers else {
                throw CheckFailure(description: "Missing indicator layers")
            }
            try expect(layers.count == 30)
            let bases = stride(from: 0, to: layers.count, by: 2).map { layers[$0] }
            let pulses = stride(from: 1, to: layers.count, by: 2).map { layers[$0] }
            let base = NSColor(cgColor: bases[0].backgroundColor!)!.usingColorSpace(.sRGB)!
            try expect(base.alphaComponent == 1)
            // A light-gray baseline in light mode, and a visible neutral baseline
            // in dark mode; neither becomes transparent when blue reaches zero.
            try expect(appearance == .aqua ? (0.8...0.95).contains(base.redComponent)
                                          : (0.15...0.4).contains(base.redComponent))
            try expect(abs(base.redComponent - base.greenComponent) < 0.01)
            try expect(abs(base.redComponent - base.blueComponent) < 0.01)
            for baseLayer in bases {
                try expect(baseLayer.opacity == 1 && (baseLayer.animationKeys() ?? []).isEmpty)
                try expect(baseLayer.backgroundColor == bases[0].backgroundColor)
            }
            for opacity: Float in [0, 0.5, 1] {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for dot in pulses { dot.opacity = opacity }
                CATransaction.commit()
                let scale: CGFloat = 4
                let context = CGContext(data: nil, width: 112, height: 64, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.scaleBy(x: scale, y: scale)
                root.render(in: context)
                let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
                let baseline = [base.redComponent, base.greenComponent, base.blueComponent]
                for dot in bases {
                    let pixel = bitmap.colorAt(x: Int(dot.frame.midX * scale), y: Int(dot.frame.midY * scale))!
                        .usingColorSpace(.sRGB)!
                    try expect(pixel.alphaComponent > 0.99)
                    let actual = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
                    if opacity == 0 {
                        // Check visible neutral gray after Core Animation's color
                        // conversion, rather than assuming raw sRGB values survive it.
                        try expect(abs(pixel.redComponent - pixel.greenComponent) < 0.01)
                        try expect(abs(pixel.redComponent - pixel.blueComponent) < 0.01)
                        try expect(appearance == .aqua ? (0.8...0.96).contains(pixel.redComponent)
                                                      : (0.15...0.45).contains(pixel.redComponent))
                    } else {
                        // Color-managed blue overlays must change the dot's color,
                        // never its opaque coverage or the underlying gray layer.
                        try expect(zip(actual, baseline).contains { abs($0 - $1) > 0.05 })
                    }
                }
            }
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
