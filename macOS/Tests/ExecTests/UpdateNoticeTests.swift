import AppKit
import SwiftUI

@MainActor
struct UpdateNoticeTests {
    func availabilityRestoresBeforeCheckingAndClearsWhenObsolete() throws {
        let suite = "UpdateAvailability.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        func launch(build: String = "1") -> UpdateNotice {
            UpdateNotice(preferences: preferences, installedBuild: build)
        }

        let firstLaunch = launch()
        try expect(!firstLaunch.isVisible)
        firstLaunch.foundUpdate(build: "4")

        let restored = launch()
        try expect(restored.availableBuild == "4" && restored.isVisible)
        try expect(!restored.beginSilentCheck(canCheck: false))
        try expect(restored.isVisible)
        try expect(restored.beginSilentCheck(canCheck: true))
        // Starting a refresh (or failing without a result) must not hide known availability.
        try expect(restored.isVisible && launch().isVisible)
        restored.foundNoUpdate()
        try expect(!restored.isVisible && !launch().isVisible)

        restored.foundUpdate(build: "4")
        try expect(!launch(build: "4").isVisible) // Installed update invalidates the cache.
        try expect(!launch().isVisible) // Invalidation also survives a subsequent launch.
        launch().foundUpdate(build: "5")
        try expect(!launch(build: "2").isVisible) // Any changed host build needs a fresh check.
        launch().foundUpdate(build: "5")
        launch().foundUpdate(build: "")
        try expect(!launch().isVisible)
    }

    func dismissalSurvivesRelaunchAndOnlyHidesThatBuild() throws {
        let suite = "UpdateNotice.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let notice = UpdateNotice(preferences: preferences, installedBuild: "1")
        try expect(!notice.isVisible)
        notice.foundUpdate(build: "4")
        try expect(notice.isVisible)
        notice.dismiss()
        try expect(!notice.isVisible)

        let restored = UpdateNotice(preferences: preferences, installedBuild: "1")
        try expect(restored.availableBuild == "4" && !restored.isVisible)
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
