import SwiftUI

@MainActor struct WorkspaceBar: View {
    @Bindable var store: ChatPanel

    var body: some View {
        Group {
            if let workspace = store.workspace {
                Label((workspace.root.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
                    .help(workspace.root.path)
                    .accessibilityLabel("Workspace: \(workspace.root.path)")
            } else {
                Label("Workspace", systemImage: "folder")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
