import SwiftUI

@MainActor struct WorkspaceBar: View {
    let root: URL

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
            Text(root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)
        }
        .lineLimit(1).truncationMode(.middle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(root.path)
        .accessibilityLabel("Workspace: \(root.path)")
    }
}
