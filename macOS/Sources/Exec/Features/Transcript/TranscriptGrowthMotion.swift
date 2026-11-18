import AppKit

/// A visual-only FLIP on the document, never a delayed logical scroll target.
/// Layout pins synchronously. Arrivals before paint coalesce into one animation;
/// overlapping arrivals start from the CURRENT presentation, not the old origin.
@MainActor final class TranscriptGrowthMotion {
    static let duration: TimeInterval = 0.18
    static let maximumOffset: CGFloat = 72
    static let animationKey = "streamGrowth"
    weak var layer: CALayer?
    private(set) var pendingOffset: CGFloat?

    func add(growth: CGFloat) {
        guard growth > 0, let layer else { return }
        let current = pendingOffset ?? (layer.presentation()?.transform.m42 ?? 0)
        // Very large/frequent bursts intentionally snap the excess rather than
        // building a visual backlog. Settling is at most 180 ms after last paint.
        pendingOffset = min(Self.maximumOffset, max(0, current) + growth)
    }

    func commit() {
        guard let offset = pendingOffset, let layer else { return }
        pendingOffset = nil
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = offset
        animation.toValue = 0
        animation.duration = Self.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: Self.animationKey)
    }

    func cancel() {
        pendingOffset = nil
        layer?.removeAnimation(forKey: Self.animationKey)
    }
}
