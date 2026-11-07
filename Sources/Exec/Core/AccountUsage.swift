import Foundation

/// Provider-reported account limits, separate from a conversation's context size.
struct AccountUsage: Codable, Equatable, Sendable {
    struct Window: Codable, Equatable, Sendable {
        let durationSeconds: Int
        let usedPercent: Double
        let resetsAt: Date
        var remainingPercent: Int { Int((100 - usedPercent).rounded(.down)) }
    }
    let windows: [Window]
}

/// Account-wide observations, not an attribution of quota cost to this session.
struct RunAllowanceObservation: Codable, Sendable {
    enum Phase: String, Codable { case before, after }
    let runID: UUID
    let phase: Phase
    let observedAt: Date
    let usage: AccountUsage?
}
