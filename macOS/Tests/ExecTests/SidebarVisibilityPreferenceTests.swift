import Foundation

@MainActor struct SidebarVisibilityPreferenceTests {
    func defaultsClosedWithoutSavingAnInferredChoice() throws {
        let suite = "exec-sidebar-preference-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }

        let visibility = SidebarVisibilityPreference(preferences: preferences)
        try expect(!visibility.isVisible)
        try expect(preferences.object(forKey: SidebarVisibilityPreference.preferenceKey) == nil)
        try expect(!SidebarVisibilityPreference(preferences: UserDefaults(suiteName: suite)!).isVisible)
    }

    func roundTripsOpenAndClosedWithoutChangingOtherPreferences() throws {
        let suite = "exec-sidebar-preference-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("untouched", forKey: "unrelated")
        let visibility = SidebarVisibilityPreference(preferences: preferences)

        for isVisible in [true, false, true] {
            visibility.isVisible = isVisible
            let restored = SidebarVisibilityPreference(preferences: UserDefaults(suiteName: suite)!)
            try expect(restored.isVisible == isVisible)
            try expect(preferences.object(forKey: SidebarVisibilityPreference.preferenceKey) as? Bool == isVisible)
            try expect(preferences.string(forKey: "unrelated") == "untouched")
        }
    }
}
