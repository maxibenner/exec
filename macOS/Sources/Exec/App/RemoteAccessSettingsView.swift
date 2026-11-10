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
                Picker("Connector", selection: $draft.managed) {
                    Text("Managed by Exec").tag(true)
                    Text("Externally managed").tag(false)
                }
                if draft.managed {
                    LabeledContent("Pangolin CLI") {
                        HStack {
                            if !draft.executable.isEmpty {
                                Text(draft.executable).lineLimit(1).truncationMode(.middle)
                                    .foregroundStyle(.secondary).help(draft.executable)
                            }
                            Button("Select…", action: selectExecutable)
                        }
                    }
                    if !FileManager.default.isExecutableFile(atPath: draft.executable) {
                        Link("Install Pangolin CLI 0.21.0…", destination: URL(string: "https://github.com/fosrl/cli/releases/tag/0.21.0")!)
                        Text("Install the Pangolin CLI, not the standalone Newt connector. Exec does not install a system service.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Pangolin URL", text: $draft.endpoint, prompt: Text("https://app.pangolin.net"))
                    TextField("Site ID", text: $draft.siteID)
                    SecureField("Site Secret", text: $draft.siteSecret)
                }
                TextField("Resource URL", text: $draft.resourceURL, prompt: Text("https://exec.example.com"))
                HStack {
                    Spacer()
                    Button("Apply") { access.apply(draft) }
                        .disabled(draft == access.configuration)
                }
            } header: {
                Text("Pangolin")
            } footer: {
                Text("Resource URL is the browser address, not the dashboard. Leave it blank for loopback-only access.")
            }

            if access.configuration == nil {
                Section("Setup") {
                    Text("1. Create a site in Pangolin and enter its connection details above.")
                    Text("2. Create an authenticated public HTTPS resource, or a private resource with restricted access, targeting HTTP → 127.0.0.1:9417 on that site.")
                    Text("3. Enter the resource’s browser URL, apply, and enable Remote Access. Open that URL to use Exec.")
                }
            }
            if let error = access.error {
                Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
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
