import Foundation

/// Provider-reported account limits, separate from a conversation's context size.
struct AccountUsage: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let durationSeconds: Int
        let usedPercent: Double
        let resetsAt: Date
        var remainingPercent: Int { Int((100 - usedPercent).rounded(.down)) }
    }
    let windows: [Window]
}
