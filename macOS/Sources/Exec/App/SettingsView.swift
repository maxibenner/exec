import SwiftUI

struct SettingsView: View {
    let store: ChatLibrary

    var body: some View {
        @Bindable var settings = store
        return TabView(selection: $settings.settingsTab) {
            ModelsAndToolsSettingsView(store: store)
                .tabItem { Label("Models & Tools", systemImage: "slider.horizontal.3") }
                .tag(ChatLibrary.SettingsTab.modelsAndTools)
            ProviderSettingsView(store: store)
                .tabItem { Label("Providers", systemImage: "person.crop.circle") }
                .tag(ChatLibrary.SettingsTab.accounts)
            UsageSettingsView(store: store)
                .tabItem { Label("Usage", systemImage: "chart.bar") }
                .tag(ChatLibrary.SettingsTab.usage)
        }
        .frame(width: 500)
        .frame(minHeight: 360, idealHeight: 560)
    }
}
