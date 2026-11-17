import Foundation

/// Continuous bottom-follow state, independent of chunk and frame cadence.
struct StreamFollowSpring {
    private(set) var position: CGFloat
    private(set) var velocity: CGFloat = 0
    private var target: CGFloat
    private var lastSample: TimeInterval
    // A step covers ~99% of the distance in 480 ms, then settles subpixel residue.
    private static let frequency: CGFloat = 14

    init(position: CGFloat, now: TimeInterval) {
        self.position = position
        target = position
        lastSample = now
    }

    var isSettled: Bool { position == target && velocity == 0 }

    mutating func retarget(to target: CGFloat, at now: TimeInterval) {
        // Integrate the OLD destination first: new content must not retroactively
        // accelerate the elapsed frame or discard the current position/velocity.
        advance(to: now)
        self.target = target
        // A measured height correction may put the bottom above the viewport.
        // Clamp to the document boundary rather than bouncing past it and back.
        if position >= target { position = target; velocity = 0 }
    }

    mutating func advance(to now: TimeInterval) {
        let dt = CGFloat(max(0, now - lastSample))
        guard dt > 0 else { return }
        lastSample = now
        let displacement = position - target
        let coefficient = velocity + Self.frequency * displacement
        let decay = exp(-Self.frequency * dt)
        // Exact solution of x'' + 2ωx' + ω²(x - target) = 0, not Euler steps.
        position = target + (displacement + coefficient * dt) * decay
        velocity = (velocity - Self.frequency * coefficient * dt) * decay
        // Critical damping cannot overshoot a growing target. A shrinking target
        // can meet existing momentum; stop at that boundary without a rebound.
        if position >= target || (abs(position - target) < 0.1 && abs(velocity) < 1) {
            position = target
            velocity = 0
        }
    }
}
