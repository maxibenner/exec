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
            systemPromptSection
                .tabItem { Label("System Prompt", systemImage: "text.alignleft") }
                .tag(ChatLibrary.SettingsTab.systemPrompt)
        }
        .frame(width: 500)
        .frame(minHeight: 360, idealHeight: 420)
    }

    private var systemPromptSection: some View {
        @Bindable var settings = store
        return GeometryReader { geometry in
            Form {
                Section("System Prompt") {
                    TextEditor(text: $settings.systemPrompt)
                        .font(.body)
                        .accessibilityLabel("System Prompt")
                        .scrollContentBackground(.hidden)
                        .frame(height: max(220, geometry.size.height - 100))
                }
            }
            .formStyle(.grouped)
        }
    }
}
