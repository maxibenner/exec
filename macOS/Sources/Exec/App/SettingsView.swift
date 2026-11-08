import SwiftUI

struct SettingsView: View {
    let store: ChatLibrary
    @State private var apiKeys: [String: String] = [:]

    var body: some View {
        TabView {
            generalSection
                .tabItem { Label("General", systemImage: "gearshape") }
            accountSection
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            systemPromptSection
                .tabItem { Label("System Prompt", systemImage: "text.alignleft") }
        }
        .frame(width: 500)
        .frame(minHeight: 360, idealHeight: 420)
    }

    private var generalSection: some View {
        @Bindable var settings = store
        return Form {
            Section("New Sessions") {
                Picker("Default model", selection: $settings.defaultModel) {
                    Text("Automatic").tag("")
                    if !store.defaultModel.isEmpty, !store.models.contains(where: { $0.id == store.defaultModel }) {
                        Text(store.defaultModel).tag(store.defaultModel)
                    }
                    ForEach(store.models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                Picker("Reasoning level", selection: $settings.defaultEffort) {
                    Text("Model default").tag(String?.none)
                    let efforts = store.defaultSessionModel?.efforts ?? []
                    if let effort = store.defaultEffort, !efforts.contains(where: { $0.id == effort }) {
                        Text(effort).tag(Optional(effort))
                    }
                    ForEach(efforts) { effort in
                        Text(effort.name).tag(Optional(effort.id))
                    }
                }
                .disabled(store.defaultSessionModel?.efforts.isEmpty != false)
                Toggle("Auto mode", isOn: $settings.defaultAutoApproveTools)
            }
            if !store.searchModels.isEmpty {
                Section("Web Search") {
                    Picker("Search model", selection: $settings.searchModel) {
                        if !store.searchModels.contains(where: { $0.id == store.searchModel }) {
                            Text(store.searchModel).tag(store.searchModel)
                        }
                        ForEach(store.searchModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                }
            }
            Section("Session Titles") {
                Toggle("Generate session titles", isOn: $settings.generatedTitlesEnabled)
                Picker("Title model", selection: $settings.titleModel) {
                    Text("Choose a model").tag("")
                    if !store.titleModel.isEmpty, !store.models.contains(where: { $0.id == store.titleModel }) {
                        Text(store.titleModel).tag(store.titleModel)
                    }
                    ForEach(store.models) { model in
                        Text(model.name).tag(model.id)
                    }
                }
                .disabled(!store.generatedTitlesEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private var accountSection: some View {
        Form {
            ForEach(store.connections) { connection in
                Section(connection.name) {
                    if let account = connection.account {
                        LabeledContent("Connected") {
                            Text(verbatim: account).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if connection.authentication == .apiKey {
                        SecureField("API key", text: Binding(
                            get: { apiKeys[connection.id] ?? "" },
                            set: { apiKeys[connection.id] = $0 }
                        ))
                        .autocorrectionDisabled()
                    }
                    HStack {
                        Button(connection.account == nil ? "Connect" : "Reconnect") {
                            let credential = apiKeys.removeValue(forKey: connection.id)
                            store.connect(providerID: connection.id, credential: credential)
                        }
                        .disabled(connection.authentication == .apiKey &&
                                  (apiKeys[connection.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if connection.account != nil {
                            Spacer()
                            Button("Disconnect", role: .destructive) { store.disconnect(providerID: connection.id) }
                        }
                    }
                }
            }
            if store.account != nil {
                Section { Button("Refresh Models", action: store.refreshModels) }
            }
        }
        .formStyle(.grouped)
        .disabled(store.accountBusy || !store.canNavigate)
        .onDisappear { apiKeys.removeAll() }
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
