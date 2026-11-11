import Foundation
import os

/// Opt-in diagnostics only; never records conversation content or account information.
@MainActor enum WorkingIndicatorProbe {
    static let enabled = ProcessInfo.processInfo.environment["EXEC_PROFILE_INDICATOR"] == "1"
    private static let log = OSLog(subsystem: "Exec", category: .pointsOfInterest)
    private(set) static var ticks = 0
    private(set) static var draws = 0
    private(set) static var drawSeconds: TimeInterval = 0

    static func tick() {
        guard enabled else { return }
        ticks += 1
        os_signpost(.event, log: log, name: "Indicator tick")
    }

    static func beginDraw() -> TimeInterval? {
        guard enabled else { return nil }
        os_signpost(.begin, log: log, name: "Indicator draw")
        return ProcessInfo.processInfo.systemUptime
    }

    static func endDraw(_ start: TimeInterval?) {
        guard let start else { return }
        drawSeconds += ProcessInfo.processInfo.systemUptime - start
        draws += 1
        os_signpost(.end, log: log, name: "Indicator draw")
    }
}
