import Foundation

/// Each running session owns an independent activity. Ending one cannot allow
/// idle sleep while another is still running. Display sleep remains unaffected.
@MainActor struct SessionSleepPrevention {
    var begin: () -> NSObjectProtocol
    var end: (NSObjectProtocol) -> Void

    static let system = SessionSleepPrevention(
        begin: {
            ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled],
                reason: "Exec is running a session"
            )
        },
        end: { ProcessInfo.processInfo.endActivity($0) }
    )
}
