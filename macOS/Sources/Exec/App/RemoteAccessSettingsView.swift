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
            } footer: {
                Text("Run Newt directly on this Mac and point a Pangolin HTTP/HTTPS resource at the target above. Use HTTPS on the phone. Exec only listens on this Mac’s loopback interface.")
            }
            Section {
                Text("The access key grants access to all existing conversations and allows messages that can run tools. Keep it private. Resetting it revokes every connected browser.")
                Text("Tool approvals remain on the Mac. Existing auto-approval settings still apply. The Mac must be awake with Exec running.")
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
