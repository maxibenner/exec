import AppKit
import SwiftUI

@MainActor struct WorkspaceBar: View {
    @Bindable var store: ChatLibrary
    @State private var folderPanel: NSOpenPanel?

    var body: some View {
        HStack(spacing: 6) {
            if let workspace = store.workspace {
                Menu {
                    Button("Change Folder…", action: chooseFolder)
                        .disabled(!store.canSelectWorkspace || folderPanel != nil)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.root]) }
                } label: {
                    Label((workspace.root.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help(workspace.root.path).accessibilityLabel("Workspace: \(workspace.root.path)")
            } else {
                Button(action: chooseFolder) { Label("Workspace…", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless).help("Choose a project folder")
                    .disabled(!store.canSelectWorkspace || folderPanel != nil)
            }
        }
        .controlSize(.small)
        .disabled(!store.canNavigate)
    }

    private func chooseFolder() {
        guard store.canSelectWorkspace, folderPanel == nil else { return }
        let destination = store.current
        let window = NSApp.mainWindow ?? NSApp.keyWindow
        let panel = NSOpenPanel()
        folderPanel = panel
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = store.workspace?.root
        panel.prompt = "Choose Workspace"
        panel.message = "The model can read and search files in this folder. File contents, the folder path, and root AGENTS.md may be sent to your model. Edits and shell commands require approval unless you explicitly enable auto-approve."
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            folderPanel = nil
            guard response == .OK, let url = panel.url,
                  store.current === destination, store.canSelectWorkspace else { return }
            store.selectWorkspace(url)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
}
