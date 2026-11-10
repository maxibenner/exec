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
            } footer: {
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
