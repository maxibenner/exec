import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatStore
    @State private var confirmingNavigation = false
    @State private var pendingSession: UUID?
    @State private var pendingDeletion: SessionSummary?
    @State private var confirmingDeletion = false

    var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store, open: { requestNavigation(to: $0) }, delete: {
                pendingDeletion = $0; confirmingDeletion = true
            })
        } detail: {
            conversation
        }
        .frame(minWidth: 740, minHeight: 480)
        .confirmationDialog("Discard unsaved content?", isPresented: $confirmingNavigation, titleVisibility: .visible) {
            Button("Continue", role: .destructive) { navigate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your saved conversations will be kept. Unsent text and changes that could not be saved will be discarded.")
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete Conversation", role: .destructive) {
                if let session = pendingDeletion { store.deleteSession(session.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(pendingDeletion?.title ?? "")” will be permanently deleted from this Mac. Files changed by its tools will not be undone.")
        }
        .task { store.restore() }
        .onDisappear { store.stop() }
    }

    private func requestNavigation(to id: UUID?) {
        guard !store.busy, id == nil || id != store.currentSessionID else { return }
        pendingSession = id
        if !store.draft.isEmpty || store.hasUnsavedChanges { confirmingNavigation = true }
        else { navigate() }
    }

    private func navigate() {
        if let pendingSession { store.openSession(pendingSession) }
        else { store.newConversation() }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack {
                if let account = store.account {
                    Menu {
                        Button("Refresh models", action: store.restore)
                        Button("Reconnect", action: store.connect)
                        Button("Sign out", action: store.disconnect)
                    } label: {
                        Text(account).lineLimit(1)
                    }
                    .disabled(store.busy)
                } else {
                    Button(store.connectionTitle, action: store.connect).disabled(store.busy)
                }
                Spacer()
                if !store.models.isEmpty {
                    Picker("Model", selection: $store.selectedModel) {
                        ForEach(store.models) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(maxWidth: 200).disabled(store.busy)
                }
                Button("New") { requestNavigation(to: nil) }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(store.busy)
            }
            .padding()
            Divider()
            WorkspaceBar(store: store)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(store.messages.filter { $0.role != .assistant || !$0.text.isEmpty || $0.toolCalls.isEmpty }) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(message.role == .user ? "You" : message.role == .tool ? "Tool" : "Assistant")
                                if message.status == .interrupted { Text("Stopped · excluded from context") }
                                if message.status == .failed { Text("Failed · excluded from context") }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            if let result = message.toolResult {
                                DisclosureGroup(result.call.name) {
                                    Text(result.call.arguments).font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                    Text(result.text).font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else if !message.text.isEmpty {
                                if message.role == .assistant {
                                    MarkdownView(source: message.text)
                                } else {
                                    Text(verbatim: message.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            if let approval = store.tools.pendingApproval {
                Divider()
                ToolApprovalView(approval: approval, executor: store.tools)
            }
            if let error = store.error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled).padding(.horizontal).padding(.bottom, 8)
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("Message", text: $store.draft, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.plain)
                    .onSubmit { store.send() }
                if store.busy {
                    ProgressView().controlSize(.small)
                    Button("Stop", action: store.stop)
                } else {
                    Button("Send", action: store.send)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(store.account == nil || store.selectedModel.isEmpty || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
