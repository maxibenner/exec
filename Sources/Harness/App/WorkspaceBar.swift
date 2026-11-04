import AppKit
import SwiftUI

@MainActor struct WorkspaceBar: View {
    @Bindable var store: ChatStore
    @State private var pendingFolder: URL?
    @State private var confirmingChange = false

    var body: some View {
        HStack(spacing: 6) {
            if let workspace = store.workspace {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(workspace.root.lastPathComponent.isEmpty ? workspace.root.path : workspace.root.lastPathComponent)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(workspace.root.path).textSelection(.enabled)
                Menu {
                    Button("Change Folder…", action: chooseFolder)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.root]) }
                    Button("Reload Instructions") { requestChange(to: workspace.root) }
                    Divider()
                    Button("Close Workspace") { requestChange(to: nil) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Workspace settings").accessibilityLabel("Workspace settings")
            } else {
                Button(action: chooseFolder) { Label("Workspace…", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless).help("Choose a project folder")
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .disabled(store.busy)
        .confirmationDialog("Start a fresh conversation?", isPresented: $confirmingChange, titleVisibility: .visible) {
            Button("Start New Conversation") { applyChange(pendingFolder) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changing, closing, or reloading a workspace starts a new conversation. The previous saved conversation is kept. Unsent text and changes that could not be saved will be discarded.")
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
        panel.message = "The model can read and search files in this folder. File contents, the folder path, and root AGENTS.md may be sent to your model. Edits and shell commands require separate approval."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { requestChange(to: url) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    private func requestChange(to folder: URL?) {
        guard !store.busy else { return }
        if !store.messages.isEmpty || !store.draft.isEmpty || store.hasUnsavedChanges {
            pendingFolder = folder
            confirmingChange = true
        } else { applyChange(folder) }
    }

    private func applyChange(_ folder: URL?) {
        if let folder { store.selectWorkspace(folder) }
        else { store.closeWorkspace() }
    }
}
