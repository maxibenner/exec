import SwiftUI

struct SessionSidebar: View {
    @Bindable var store: ChatStore
    let open: (UUID) -> Void
    let delete: (SessionSummary) -> Void

    var body: some View {
        List(selection: Binding(get: { store.currentSessionID }, set: { if let id = $0 { open(id) } })) {
            Section("Sessions") {
                ForEach(store.sessionList) { session in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: session.title).lineLimit(2)
                            if let workspace = session.workspace {
                                Text(URL(fileURLWithPath: workspace).lastPathComponent)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(workspace)
                            }
                            if !session.unreadable {
                                Text(session.updatedAt, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Button(role: .destructive) { delete(session) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .help("Delete conversation").accessibilityLabel("Delete \(session.title)")
                    }
                    .padding(.vertical, 4)
                    .tag(session.id)
                    .contextMenu { Button("Delete Conversation…", role: .destructive) { delete(session) } }
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(store.busy)
        .onDeleteCommand {
            if let selected = store.sessionList.first(where: { $0.id == store.currentSessionID }) { delete(selected) }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 320)
    }
}
