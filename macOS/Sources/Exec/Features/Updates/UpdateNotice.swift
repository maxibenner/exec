import Foundation
import Observation

/// Presentation state, separate from Sparkle so dismissal and timing use isolated tests.
@MainActor @Observable
final class UpdateNotice {
    private(set) var availableBuild: String?
    private var dismissedBuild: String?
    private var lastCheck: Date?
    private let preferences: UserDefaults
    private let installedBuild: String
    private static let dismissalKey = "dismissedUpdateBadgeBuild"
    private static let availabilityKey = "availableUpdateBadge"

    init(preferences: UserDefaults = .standard,
         installedBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") {
        self.preferences = preferences
        self.installedBuild = installedBuild
        dismissedBuild = preferences.string(forKey: Self.dismissalKey)
        // Restore before the first frame, but never carry a notice across app builds.
        if !installedBuild.isEmpty,
           let saved = preferences.dictionary(forKey: Self.availabilityKey) as? [String: String],
           saved["installedBuild"] == installedBuild,
           let build = saved["availableBuild"], !build.isEmpty {
            availableBuild = build
        } else {
            preferences.removeObject(forKey: Self.availabilityKey)
        }
    }

    var isVisible: Bool {
        guard let availableBuild else { return false }
        return availableBuild != dismissedBuild
    }

    func foundUpdate(build: String) {
        guard !build.isEmpty else {
            foundNoUpdate()
            return
        }
        availableBuild = build
        preferences.set(["installedBuild": installedBuild, "availableBuild": build],
                        forKey: Self.availabilityKey)
    }

    func foundNoUpdate() {
        availableBuild = nil
        preferences.removeObject(forKey: Self.availabilityKey)
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
