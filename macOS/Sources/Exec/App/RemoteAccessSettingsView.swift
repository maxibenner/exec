import SwiftUI

struct RemoteAccessSettingsView: View {
    let access: RemoteAccess
    @State private var draft = PangolinConfiguration()

    private var connectionColor: Color {
        switch access.connectionState {
        case .notConnected: .red
        case .connecting: .yellow
        case .connected: .green
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Remote Access", isOn: Binding(get: { access.enabled }, set: access.setEnabled))
            } footer: {
                Text("This exposes a remote interface at port \(String(RemoteAccess.port)) and connects it to the given Pangolin resource. All local connections are trusted. Make sure to properly protect access through Pangolin.")
                    .font(.caption)
                    .multilineTextAlignment(.leading)
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
                    LabeledContent("Site Secret") {
                        SecureField("Site Secret", text: $draft.siteSecret)
                            .labelsHidden()
                            .frame(width: 140)
                    }
                    TextField("Resource URL", text: $draft.resourceURL, prompt: Text(verbatim: "https://exec.example.com"))
                }
                .frame(minHeight: 24, alignment: .center)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
            } header: {
                HStack(alignment: .bottom, spacing: 8) {
                    Text("Pangolin")
                    Text(access.connectionState.rawValue)
                        .font(.caption)
                        .foregroundStyle(connectionColor)
                }
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

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Setup").bold()
                        setupStep(1, "Create a new Pangolin site and paste the url, id and secret.")
                        setupStep(2, "Create a new resource and connect it to the port specified above.")
                        setupStep(3, "Make sure the Pangolin CLI is installed.")
                    }
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .padding(.vertical, 24)
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.regular)
        .alert("Remote Access", isPresented: Binding(
            get: { access.error != nil },
            set: { if !$0 { access.dismissError() } }
        )) {
            Button("OK", role: .cancel, action: access.dismissError)
        } message: {
            Text(access.error ?? "")
        }
        .onAppear {
            access.loadConfiguration()
            draft = access.configuration ?? PangolinConfiguration()
            if draft.executable.isEmpty { draft.executable = PangolinConfiguration.discover() ?? "" }
        }
    }

    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
            Text(text).fixedSize(horizontal: false, vertical: true)
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
