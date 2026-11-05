import SwiftUI

struct AutoApprovalToggle: View {
    @Bindable var store: ChatLibrary

    var body: some View {
        Toggle("Auto-approve", isOn: Binding(get: { store.autoApproveTools }, set: { enabled in
            store.setAutoApproveTools(enabled)
        }))
        .toggleStyle(.switch).controlSize(.mini).font(.caption).fixedSize()
        .disabled(store.workspace == nil || store.account == nil || (store.isWorking && !store.isSending))
        .allowsHitTesting(store.canNavigate)
        .help("Automatically approve edits and shell commands for this conversation")
    }
}
