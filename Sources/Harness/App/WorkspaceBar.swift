import AppKit
import SwiftUI

@MainActor struct WorkspaceBar: View {
    @Bindable var store: ChatStore
    @State private var pendingFolder: URL?
    @State private var confirmingChange = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
            VStack(alignment: .leading, spacing: 3) {
                Text(store.workspace?.root.path ?? "No workspace selected")
                    .font(.callout).lineLimit(1).truncationMode(.middle)
                    .help(store.workspace?.root.path ?? "Choose a project folder to load its instructions.")
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Group {
                if let workspace = store.workspace {
                    Menu("Workspace") {
                        Button("Change Folder…", action: chooseFolder)
                        Button("Reload Instructions") { requestChange(to: workspace.root) }
                        Divider()
                        Button("Close Workspace") { requestChange(to: nil) }
                    }
                    .fixedSize()
                } else {
                    Button("Choose Folder…", action: chooseFolder)
                }
            }
            .disabled(store.busy)
        }
        .padding(.horizontal).padding(.vertical, 10)
        .confirmationDialog("Start a fresh conversation?", isPresented: $confirmingChange, titleVisibility: .visible) {
            Button("Start New Conversation", role: .destructive) { applyChange(pendingFolder) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changing, closing, or reloading a workspace clears this conversation and its draft. Project instructions will be included with future messages.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = store.workspace?.root
        panel.prompt = "Choose Workspace"
        panel.message = "The model can read and search files in this folder. File contents, the folder path, and root AGENTS.md may be sent to your model. Shell commands require separate approval."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { requestChange(to: url) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func requestChange(to folder: URL?) {
        guard !store.busy else { return }
        if !store.messages.isEmpty || !store.draft.isEmpty {
            pendingFolder = folder
            confirmingChange = true
        } else { applyChange(folder) }
    }

    private func applyChange(_ folder: URL?) {
        if let folder { store.selectWorkspace(folder) }
        else { store.closeWorkspace() }
    }
}
