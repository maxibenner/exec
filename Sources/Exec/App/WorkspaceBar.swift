import SwiftUI

@MainActor struct WorkspaceBar: View {
    let root: URL?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
            Text(root.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent } ?? " ")
        }
        .lineLimit(1).truncationMode(.middle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(root?.path ?? "")
        .accessibilityLabel(root.map { "Workspace: \($0.path)" } ?? "")
        // Keep a real toolbar item mounted before the workspace is restored.
        // An EmptyView lets AppKit remove and later reinsert the toolbar.
        .opacity(root == nil ? 0 : 1)
        .accessibilityHidden(root == nil)
    }
}
