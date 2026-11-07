import AppKit
import SwiftUI

@MainActor struct ProviderUsageFooterTests {
    func remainingAllowanceAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let short = AccountUsage.Window(durationSeconds: 18_000, usedPercent: 7.2, resetsAt: now)
        let weekly = AccountUsage.Window(durationSeconds: 604_800, usedPercent: 100, resetsAt: now.addingTimeInterval(60))
        let usage = AccountUsage(windows: [short, weekly])
        try expect(usage.activeWindows(at: now.addingTimeInterval(-1)).map(\.remainingPercent) == [92, 0])
        try expect(usage.activeWindows(at: now) == [weekly])
        // A reset does not imply 100% remaining without a new provider report.
        try expect(usage.activeWindows(at: weekly.resetsAt).isEmpty)
        try expect(AccountUsageLabel.name(short.durationSeconds) == "5-hour")
        try expect(AccountUsageLabel.name(weekly.durationSeconds) == "Weekly")
    }

    func fitsSidebarWidths() throws {
        _ = NSApplication.shared
        let reset = Date().addingTimeInterval(3_600)
        let usage = AccountUsage(windows: [
            .init(durationSeconds: 18_000, usedPercent: 0, resetsAt: reset),
            .init(durationSeconds: 604_800, usedPercent: 100, resetsAt: reset)
        ])
        for width in [200, 320] {
            for scheme in [ColorScheme.light, .dark] {
                for value in [usage, nil] {
                    let view = ProviderUsageFooter(providerName: "Test Provider", usage: value)
                        .frame(width: CGFloat(width))
                        .environment(\.colorScheme, scheme)
                    let hosting = NSHostingView(rootView: view)
                    let size = hosting.fittingSize
                    try expect(abs(size.width - CGFloat(width)) < 1)
                    try expect(size.height > 40 && size.height <= 110)
                }
            }
        }
    }
}
