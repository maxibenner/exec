import AppKit
import SwiftUI

@MainActor struct WorkspaceBar: View {
    @Bindable var store: ChatPanel

    var body: some View {
        HStack(spacing: 6) {
            if let workspace = store.workspace {
                Menu {
                    Button("Change Folder…", action: store.chooseWorkspace)
                        .disabled(!store.canChooseWorkspace)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.root]) }
                    Button("Open in Terminal", action: store.openWorkspaceInTerminal)
                } label: {
                    Label((workspace.root.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help(workspace.root.path).accessibilityLabel("Workspace: \(workspace.root.path)")
            } else {
                Button(action: store.chooseWorkspace) { Label("Workspace…", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless).help("Choose a project folder")
                    .disabled(!store.canChooseWorkspace)
            }
        }
        .controlSize(.small)
        .disabled(!store.canNavigate)
    }

}
