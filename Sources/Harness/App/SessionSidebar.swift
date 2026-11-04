import SwiftUI

struct SessionSidebar: View {
    @Bindable var store: ChatStore
    let open: (UUID) -> Void
    let delete: (SessionSummary) -> Void
    @State private var confirmingSignOut = false

    var body: some View {
        List(selection: Binding(get: { store.currentSessionID }, set: { if let id = $0 { open(id) } })) {
            Section("Sessions") {
                ForEach(store.sessionList) { session in
                    SessionRow(session: session, selected: session.id == store.currentSessionID, delete: { delete(session) })
                        .tag(session.id)
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(store.busy)
        .onDeleteCommand {
            guard !store.busy else { return }
            if let selected = store.sessionList.first(where: { $0.id == store.currentSessionID }) { delete(selected) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Group {
                    if let account = store.account {
                        Menu {
                            Button("Refresh Models", action: store.restore)
                            Button("Reconnect", action: store.connect)
                            Divider()
                            Button("Sign Out…", role: .destructive) { confirmingSignOut = true }
                        } label: {
                            Label { Text(verbatim: account).lineLimit(1).truncationMode(.middle) }
                            icon: { Image(systemName: "person.crop.circle") }
                        }
                        .menuStyle(.borderlessButton).help(account).accessibilityLabel("Account: \(account)")
                    } else {
                        Button(store.connectionTitle, action: store.connect)
                            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    }
                }
                .disabled(store.busy).padding(14)
            }
        }
        .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive, action: store.disconnect)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved conversations stay on this Mac. Unsent text and changes that could not be saved will be discarded.")
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let selected: Bool
    let delete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: session.title).font(.body.weight(selected ? .medium : .regular)).lineLimit(2)
                HStack {
                    if let workspace = session.workspace {
                        Text(URL(fileURLWithPath: workspace).lastPathComponent).lineLimit(1).help(workspace)
                    }
                    Spacer(minLength: 4)
                    if !session.unreadable {
                        Text(session.updatedAt, format: .dateTime.month(.abbreviated).day()).fixedSize()
                            .help(session.updatedAt.formatted(date: .long, time: .shortened))
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Group {
                if hovered || selected {
                    Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Delete conversation").accessibilityLabel("Delete \(session.title)")
                } else {
                    Color.clear
                }
            }
            .frame(width: 16, height: 20)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu { Button("Delete Conversation…", role: .destructive, action: delete) }
        .accessibilityAction(named: "Delete Conversation", delete)
    }
}
