import AppKit
import SwiftUI

@MainActor
struct UpdateNoticeTests {
    func dismissalSurvivesRelaunchAndOnlyHidesThatBuild() throws {
        let suite = "UpdateNotice.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let notice = UpdateNotice(preferences: preferences)
        try expect(!notice.isVisible)
        notice.foundUpdate(build: "4")
        try expect(notice.isVisible)
        notice.dismiss()
        try expect(!notice.isVisible)

        let restored = UpdateNotice(preferences: preferences)
        restored.foundUpdate(build: "4") // A quiet or manual check must not undo dismissal.
        try expect(!restored.isVisible)
        restored.foundUpdate(build: "5")
        try expect(restored.isVisible)
        restored.foundNoUpdate() // Removed, incompatible, or already installed.
        try expect(!restored.isVisible)
        restored.foundUpdate(build: "4")
        try expect(!restored.isVisible)
    }

    func silentChecksAreThrottledAndDoNotConsumeBusyAttempts() throws {
        let suite = "UpdateChecks.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let notice = UpdateNotice(preferences: preferences)
        let start = Date(timeIntervalSince1970: 1_000_000)
        try expect(!notice.beginSilentCheck(canCheck: false, now: start))
        try expect(notice.beginSilentCheck(canCheck: true, now: start))
        // Even a failed network check must not be retried on every activation.
        try expect(!notice.beginSilentCheck(canCheck: true, now: start.addingTimeInterval(60)))
        try expect(!notice.beginSilentCheck(canCheck: true, now: start.addingTimeInterval(21_599)))
        try expect(!notice.beginSilentCheck(canCheck: false, now: start.addingTimeInterval(21_600)))
        try expect(notice.beginSilentCheck(canCheck: true, now: start.addingTimeInterval(21_600)))
        // A backwards clock adjustment must not suppress checks indefinitely.
        try expect(notice.beginSilentCheck(canCheck: true, now: start))
    }

    func badgeFitsSidebarWidths() throws {
        _ = NSApplication.shared
        for width in [200.0, 240.0, 320.0] {
            for dark in [false, true] {
                let host = NSHostingView(rootView:
                    UpdateBadge(canCheckForUpdates: true, update: {}, dismiss: {})
                        .padding(12)
                        .frame(width: width)
                        .environment(\.colorScheme, dark ? .dark : .light))
                host.layoutSubtreeIfNeeded()
                try expect(abs(host.fittingSize.width - width) < 1)
                try expect(host.fittingSize.height >= 44 && host.fittingSize.height < 80)
            }
        }
    }
}
