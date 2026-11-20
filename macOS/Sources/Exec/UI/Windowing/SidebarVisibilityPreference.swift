import Foundation

/// Keep the user's sidebar choice independent of the session catalog and window lifetime.
@MainActor struct SidebarVisibilityPreference {
    static let preferenceKey = "mainWindowSidebarVisible.v1"

    private let preferences: UserDefaults

    init(preferences: UserDefaults) {
        self.preferences = preferences
    }

    var isVisible: Bool {
        get { preferences.bool(forKey: Self.preferenceKey) }
        nonmutating set { preferences.set(newValue, forKey: Self.preferenceKey) }
    }
}
