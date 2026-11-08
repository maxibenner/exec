import SwiftUI

struct SettingsView: View {
    let store: ChatLibrary

    var body: some View {
        @Bindable var settings = store
        return TabView(selection: $settings.settingsTab) {
            generalSection
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(ChatLibrary.SettingsTab.general)
            ProviderSettingsView(store: store)
                .tabItem { Label("Providers", systemImage: "person.crop.circle") }
                .tag(ChatLibrary.SettingsTab.accounts)
            systemPromptSection
                .tabItem { Label("System Prompt", systemImage: "text.alignleft") }
                .tag(ChatLibrary.SettingsTab.systemPrompt)
        }
        .frame(width: 500)
        .frame(minHeight: 360, idealHeight: 420)
    }

    private var generalSection: some View {
        @Bindable var settings = store
        return Form {
            if !store.hasConnectedProvider {
                Section {
                    Button("Connect a Provider…") { store.settingsTab = .accounts }
                }
            }
            Section("New Sessions") {
                if store.hasConnectedProvider {
                    Picker("Default model", selection: Binding(
                        get: { store.effectiveDefaultModel }, set: { store.defaultModel = $0 }
                    )) {
                        Text("Automatic").tag("")
                        ModelPickerOptions(groups: store.modelGroups)
                    }
                    .disabled(store.models.isEmpty)
                    Picker("Reasoning level", selection: Binding(
                        get: { store.effectiveDefaultEffort }, set: { store.setDefaultEffort($0) }
                    )) {
                        Text("Model default").tag(String?.none)
                        ForEach(store.defaultSessionModel?.efforts ?? []) { effort in
                            Text(effort.name).tag(Optional(effort.id))
                        }
                    }
                    .disabled(store.defaultSessionModel?.efforts.isEmpty != false)
                }
                Toggle("Auto mode", isOn: $settings.defaultAutoApproveTools)
            }
            if !store.searchModels.isEmpty {
                Section("Web Search") {
                    Picker("Search model", selection: Binding(
                        get: { store.effectiveSearchModel }, set: { store.searchModel = $0 }
                    )) {
                        ForEach(store.searchModels) { Text($0.name).tag($0.id) }
                    }
                }
            }
            Section("Session Titles") {
                Toggle("Generate session titles", isOn: $settings.generatedTitlesEnabled)
                if store.hasConnectedProvider {
                    Picker("Title model", selection: Binding(
                        get: { store.effectiveTitleModel }, set: { store.titleModel = $0 }
                    )) {
                        Text("Same as chat model").tag("")
                        ModelPickerOptions(groups: store.modelGroups)
                    }
                    .disabled(!store.generatedTitlesEnabled || store.models.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(store.authenticating)
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
