import SwiftUI

struct SettingsView: View {
    let store: ChatLibrary

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
            Section("Account") {
                if let account = store.account {
                    LabeledContent("Signed in as") {
                        Text(verbatim: account)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("Refresh Models", action: store.restore)
                        Button("Reconnect", action: store.connect)
                        Spacer()
                        Button("Sign Out", role: .destructive, action: store.disconnect)
                    }
                } else {
                    Button("Sign In", action: store.connect)
                }
            }
            .disabled(store.accountBusy || !store.canNavigate)
        }
        .formStyle(.grouped)
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
