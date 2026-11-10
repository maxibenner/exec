import SwiftUI

struct ModelsAndToolsSettingsView: View {
    @AppStorage(ToolDisplayPreferences.descriptiveShellTitlesKey) private var descriptiveShellTitles = false
    let store: ChatLibrary
    private var connected: [ProviderConnection] { store.connectedProviders }

    var body: some View {
        Form {
            Section("Tool Titles") {
                Toggle("Descriptive shell titles", isOn: $descriptiveShellTitles)
            }
            providerSettings
        }
        .formStyle(.grouped)
    }

    private var providerSettings: some View {
        @Bindable var settings = store
        return Group {
            if connected.isEmpty {
                Section { Text("No providers connected").foregroundStyle(.secondary) }
            }
            Section {
                if !connected.isEmpty {
                    Picker("New chat model", selection: Binding(
                        get: { store.effectiveDefaultModel }, set: { store.defaultModel = $0 }
                    )) {
                        Text(store.models.isEmpty ? "No models available" : "Automatic").tag("")
                        ModelPickerOptions(groups: store.modelGroups)
                    }
                    .disabled(store.models.isEmpty)
                    if store.defaultSessionModel?.efforts.isEmpty == false {
                        Picker("Default reasoning", selection: Binding(
                            get: { store.effectiveDefaultEffort }, set: { store.setDefaultEffort($0) }
                        )) {
                            Text("Model default").tag(String?.none)
                            ForEach(store.defaultSessionModel?.efforts ?? []) { effort in
                                Text(effort.name).tag(Optional(effort.id))
                            }
                        }
                    }
                }
                Toggle("Auto mode", isOn: $settings.defaultAutoApproveTools)
            } header: {
                Text("New Chats")
            }
            Section("Session Titles") {
                Toggle("Generate session titles", isOn: $settings.generatedTitlesEnabled)
                    .disabled(connected.isEmpty || store.models.isEmpty)
                if !connected.isEmpty {
                    Picker("Title model", selection: Binding(
                        get: { store.effectiveTitleModel }, set: { store.titleModel = $0 }
                    )) {
                        Text("Same as chat model").tag("")
                        ModelPickerOptions(groups: store.modelGroups)
                    }
                    .disabled(!store.generatedTitlesEnabled || store.models.isEmpty)
                }
            }
            if !connected.isEmpty {
                Section {
                    ForEach(connected) { connection in
                        searchSettings(connection)
                    }
                } header: {
                    Text("Web Search")
                } footer: {
                    Text("Uses the provider selected in each chat.")
                }
                Section {
                    ForEach(connected) { connection in
                        LabeledContent(connection.name,
                                       value: connection.supportsImageGeneration ? "Available" : "Unavailable")
                    }
                } header: {
                    Text("Image Generation")
                } footer: {
                    Text("Uses the provider selected in each chat.")
                }
            }
        }
        .disabled(store.authenticating || connected.isEmpty)
    }

    @ViewBuilder private func searchSettings(_ connection: ProviderConnection) -> some View {
        switch connection.webSearch {
        case .unavailable:
            LabeledContent(connection.name, value: "Unavailable")
        case .service(let name):
            LabeledContent(connection.name, value: name)
        case .model:
            let models = store.searchModels(for: connection.id)
            if models.isEmpty {
                LabeledContent(connection.name, value: "Unavailable")
            } else {
                Picker(connection.name, selection: Binding(
                    get: { models.first { $0.id == store.searchModel }?.id ?? models[0].id },
                    set: { store.searchModel = $0 }
                )) {
                    ForEach(models) { Text($0.name).tag($0.id) }
                }
            }
        }
    }
}
