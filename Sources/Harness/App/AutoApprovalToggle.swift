import SwiftUI

struct AutoApprovalToggle: View {
    @Bindable var store: ChatLibrary
    @State private var confirming = false
    @State private var targetID: UUID?

    var body: some View {
        Toggle("Auto-approve", isOn: Binding(get: { store.autoApproveTools }, set: { enabled in
            if enabled { targetID = store.currentSessionID; confirming = true }
            else { store.setAutoApproveTools(false) }
        }))
        .toggleStyle(.switch).controlSize(.mini).font(.caption).fixedSize()
        .disabled(store.workspace == nil || store.account == nil || (store.isWorking && !store.isSending))
        .allowsHitTesting(store.canNavigate)
        .help("Automatically approve edits and shell commands for this conversation")
        .confirmationDialog("Enable auto-approve?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Enable Auto-approve", role: .destructive) {
                if targetID == store.currentSessionID { store.setAutoApproveTools(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The pending request and future edits and shell commands in this conversation will run without individual prompts, including while it runs in the background. Shell commands are not sandboxed: they can access files outside the workspace, use the network, or delete data. This permission is not saved across app restarts. Turning it off affects future approvals. Use Stop to cancel current work; work already done is not undone.")
        }
    }
}
