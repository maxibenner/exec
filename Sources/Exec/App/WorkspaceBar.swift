import SwiftUI

@MainActor struct WorkspaceBar: View {
    let root: URL?

    var body: some View {
        Group {
            if let root {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent)
                }
                    .lineLimit(1).truncationMode(.middle)
                    .help(root.path)
                    .accessibilityLabel("Workspace: \(root.path)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
