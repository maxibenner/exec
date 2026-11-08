import Foundation
import Observation

/// Presentation state, separate from Sparkle so dismissal and timing use isolated tests.
@MainActor @Observable
final class UpdateNotice {
    private(set) var availableBuild: String?
    private var dismissedBuild: String?
    private var lastCheck: Date?
    private let preferences: UserDefaults
    private static let dismissalKey = "dismissedUpdateBadgeBuild"

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        dismissedBuild = preferences.string(forKey: Self.dismissalKey)
    }

    var isVisible: Bool {
        guard let availableBuild else { return false }
        return availableBuild != dismissedBuild
    }

    func foundUpdate(build: String) {
        availableBuild = build.isEmpty ? nil : build
    }

    func foundNoUpdate() {
        availableBuild = nil
    }

    func dismiss() {
        guard let availableBuild else { return }
        dismissedBuild = availableBuild
        preferences.set(availableBuild, forKey: Self.dismissalKey)
    }

    /// Check on launch and later activations, no more than once per six hours.
    /// Record attempts, not successes, so offline failures don't retry on every focus change.
    func beginSilentCheck(canCheck: Bool, now: Date = .now) -> Bool {
        guard canCheck else { return false }
        if let lastCheck {
            let elapsed = now.timeIntervalSince(lastCheck)
            if elapsed >= 0 && elapsed < 6 * 60 * 60 { return false }
        }
        lastCheck = now
        return true
    }
}
