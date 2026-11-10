import SwiftUI

struct RemoteAccessSettingsView: View {
    let access: RemoteAccess
    @State private var draft = PangolinConfiguration()

    var body: some View {
        Form {
            Section {
                Toggle("Enable Remote Access", isOn: Binding(get: { access.enabled }, set: access.setEnabled))
            } footer: {
                Text("Pangolin controls who can access Exec. Local connections on this Mac are trusted. No additional Exec login is required.")
            }

            Section {
                LabeledContent("Pangolin CLI") {
                    HStack(alignment: .center, spacing: 8) {
                        if !draft.executable.isEmpty {
                            Text(draft.executable).lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary).help(draft.executable)
                        }
                        Button("Select…", action: selectExecutable)
                            .buttonStyle(.bordered)
                    }
                }
                .frame(minHeight: 24, alignment: .center)
                if !FileManager.default.isExecutableFile(atPath: draft.executable) {
                    Link("Install Pangolin CLI 0.21.0…", destination: URL(string: "https://github.com/fosrl/cli/releases/tag/0.21.0")!)
                    Text("Install the Pangolin CLI, not the standalone Newt connector. Exec does not install a system service.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Group {
                    TextField("Pangolin URL", text: $draft.endpoint, prompt: Text(verbatim: "https://app.pangolin.net"))
                    TextField("Site ID", text: $draft.siteID)
                    SecureField("Site Secret", text: $draft.siteSecret)
                    TextField("Resource URL", text: $draft.resourceURL, prompt: Text(verbatim: "https://exec.example.com"))
                }
                .frame(minHeight: 24, alignment: .center)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
            } header: {
                Text("Pangolin")
            } footer: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        Button("Apply") { access.apply(draft) }
                            .disabled(draft == access.configuration)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .font(.body)

                    if let error = access.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if access.configuration == nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Setup").fontWeight(.medium)
                            Text("• Create a site in Pangolin and enter its connection details above.")
                            Text("• Create an authenticated public HTTPS resource, or a private resource with restricted access, targeting HTTP → 127.0.0.1:9417 on that site.")
                            Text("• Enter the resource’s browser URL, apply, and enable Remote Access. Open that URL to use Exec.")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.regular)
        .onAppear {
            access.loadConfiguration()
            draft = access.configuration ?? PangolinConfiguration()
            if draft.executable.isEmpty { draft.executable = PangolinConfiguration.discover() ?? "" }
        }
    }

    private func selectExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Select Pangolin CLI"
        panel.message = "Choose the Pangolin CLI 0.21.0 executable, not Newt."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { draft.executable = url.path }
    }
}
