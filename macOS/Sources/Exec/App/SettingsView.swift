import SwiftUI

struct SettingsView: View {
    let store: ChatLibrary
    let canCheckForUpdates: Bool
    let checkForUpdates: () -> Void
    var remoteAccess: RemoteAccess? = nil

    var body: some View {
        @Bindable var settings = store
        return TabView(selection: $settings.settingsTab) {
            ModelsAndToolsSettingsView(store: store)
                .tabItem { Label("Models & Tools", systemImage: "slider.horizontal.3") }
                .tag(ChatLibrary.SettingsTab.modelsAndTools)
            SystemPromptSettingsView(store: store)
                .tabItem { Label("System Prompt", systemImage: "text.alignleft") }
                .tag(ChatLibrary.SettingsTab.systemPrompt)
            ProviderSettingsView(store: store)
                .tabItem { Label("Providers", systemImage: "person.crop.circle") }
                .tag(ChatLibrary.SettingsTab.accounts)
            UsageSettingsView(store: store)
                .tabItem { Label("Usage", systemImage: "chart.bar") }
                .tag(ChatLibrary.SettingsTab.usage)
            if let remoteAccess {
                RemoteAccessSettingsView(access: remoteAccess)
                    .tabItem {
                        Label {
                            Text("Remote Access")
                        } icon: {
                            Image(systemName: "iphone")
                                .renderingMode(.template)
                                .symbolRenderingMode(.monochrome)
                        }
                    }
                    .tag(ChatLibrary.SettingsTab.remoteAccess)
            }
            UpdatesSettingsView(canCheckForUpdates: canCheckForUpdates, checkForUpdates: checkForUpdates)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
                .tag(ChatLibrary.SettingsTab.updates)
        }
        .frame(width: 500)
        .frame(minHeight: 360, idealHeight: 560)
    }
}
