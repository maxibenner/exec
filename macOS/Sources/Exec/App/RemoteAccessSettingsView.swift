import SwiftUI

struct RemoteAccessSettingsView: View {
    let access: RemoteAccess
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Remote Access", isOn: Binding(get: { access.enabled }, set: access.setEnabled))
                LabeledContent("Newt target") {
                    Text(RemoteAccess.address).textSelection(.enabled).font(.system(.body, design: .monospaced))
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pangolin")
                    Text("Enabling remote access starts Exec’s local web interface on port \(RemoteAccess.port).")
                        .font(.caption)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Open Local Frontend") {
                            NSWorkspace.shared.open(URL(string: RemoteAccess.address)!)
                        }
                        .disabled(!access.listening)
                        Button("Copy Access Key") {
                            do {
                                let key = try access.accessKey()
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(key, forType: .string)
                            } catch { access.report(error) }
                        }
                        .disabled(!access.enabled)
                        Button("Reset Key…") { confirmingReset = true }
                            .disabled(!access.enabled)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .font(.body)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quick setup").fontWeight(.medium)
                        Text("• Create a site in Pangolin and run its Newt connector directly on this Mac.")
                        Text("• Add an authenticated HTTPS resource targeting HTTP at 127.0.0.1:9417.")
                        Text("• Open the resource’s HTTPS URL in your browser and enter the Exec access key.")
                    }
                    .foregroundStyle(.secondary)
                }
                // Grouped-form footers inherit a 10-point content inset.
                .padding(.leading, -10)
            }
            if let error = access.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .alert("Reset mobile access key?", isPresented: $confirmingReset) {
            Button("Reset Key", role: .destructive, action: access.resetKey)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All browsers will need the new key. Active agent turns will not be stopped.")
        }
    }
}
