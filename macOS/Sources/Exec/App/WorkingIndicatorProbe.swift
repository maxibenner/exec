import Foundation
import os

/// Opt-in diagnostics only; never records conversation content or account information.
@MainActor enum WorkingIndicatorProbe {
    static let enabled = ProcessInfo.processInfo.environment["EXEC_PROFILE_INDICATOR"] == "1"
    private static let log = OSLog(subsystem: "Exec", category: .pointsOfInterest)
    private(set) static var animationStarts = 0
    private(set) static var activeAnimations = 0

    static func animationsStarted(_ count: Int) {
        guard enabled else { return }
        animationStarts += count
        activeAnimations += count
        os_signpost(.event, log: log, name: "Indicator animations started", "layers=%d", count)
    }

    static func animationsStopped(_ count: Int) {
        guard enabled else { return }
        activeAnimations -= count
        os_signpost(.event, log: log, name: "Indicator animations stopped", "layers=%d", count)
    }
}
