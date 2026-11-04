import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatStore
    @State private var confirmingNavigation = false
    @State private var pendingSession: UUID?
    @State private var pendingDeletion: SessionSummary?
    @State private var confirmingDeletion = false
    @FocusState private var composerFocused: Bool
    @State private var errorHeight: CGFloat = 20

    var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store, open: { requestNavigation(to: $0) }, delete: {
                guard !store.busy else { return }
                pendingDeletion = $0; confirmingDeletion = true
            })
        } detail: {
            VStack(spacing: 0) {
                TranscriptView(messages: store.messages, sessionID: store.currentSessionID)
                if let approval = store.tools.pendingApproval {
                    Divider()
                    ToolApprovalView(approval: approval, executor: store.tools).layoutPriority(1)
                }
                if let error = store.error { errorView(error) }
                composer
            }
            .frame(minWidth: 460)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { requestNavigation(to: nil) } label: {
                        Label("New Conversation", systemImage: "square.and.pencil")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New conversation (⌘N)")
                    .disabled(store.busy)
                }
            }
            .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        .frame(minWidth: 720, minHeight: 480)
        .confirmationDialog("Discard unsaved content?", isPresented: $confirmingNavigation, titleVisibility: .visible) {
            Button("Continue", role: .destructive) { navigate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved conversations will be kept. Unsent text and changes that could not be saved will be discarded.")
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete Conversation", role: .destructive) {
                if let session = pendingDeletion { store.deleteSession(session.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(pendingDeletion?.title ?? "")” will be permanently deleted from this Mac. Files changed by its tools will not be undone.")
        }
        .task { store.restore(); composerFocused = true }
        .onDisappear { store.stop() }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                WorkspaceBar(store: store)
                if !store.models.isEmpty || !store.selectedModel.isEmpty {
                    Picker("Model", selection: $store.selectedModel) {
                        ForEach(store.models) { Text($0.name).tag($0.id) }
                        if !store.selectedModel.isEmpty && !store.models.contains(where: { $0.id == store.selectedModel }) {
                            Text(store.selectedModel).tag(store.selectedModel)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small)
                    .frame(maxWidth: 180, alignment: .trailing).disabled(store.busy)
                    .accessibilityLabel("Model")
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message", text: $store.draft, axis: .vertical)
                    .lineLimit(1...8).textFieldStyle(.plain).font(.body)
                    .focused($composerFocused)
                    .disabled(store.busy && !store.isSending)
                    .accessibilityLabel("Message")
                    .onSubmit { store.send() }
                    .padding(.vertical, 5)
                if store.busy {
                    if store.tools.pendingApproval == nil {
                        ProgressView().controlSize(.small).padding(.bottom, 6).accessibilityLabel("Working")
                    }
                    Button(action: store.stop) { Image(systemName: "stop.fill").frame(width: 18, height: 18) }
                        .buttonStyle(.bordered).buttonBorderShape(.circle)
                        .keyboardShortcut(".", modifiers: .command)
                        .help("Stop (⌘.)").accessibilityLabel("Stop")
                } else {
                    Button(action: store.send) { Image(systemName: "arrow.up").fontWeight(.semibold).frame(width: 18, height: 18) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send message (⌘Return)").accessibilityLabel("Send message")
                        .disabled(store.account == nil || store.selectedModel.isEmpty || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5) }
        .frame(maxWidth: 820)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
            ScrollView {
                Text(verbatim: error).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { errorHeight = $0 }
            }
            .defaultScrollAnchor(.topLeading)
            .frame(height: min(100, max(20, errorHeight)))
            Button { store.error = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Dismiss error").accessibilityLabel("Dismiss error")
        }
        .padding(12).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 820).padding(.horizontal, 20).padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private func requestNavigation(to id: UUID?) {
        guard !store.busy, id == nil || id != store.currentSessionID else { return }
        pendingSession = id
        if !store.draft.isEmpty || store.hasUnsavedChanges { confirmingNavigation = true }
        else { navigate() }
    }

    private func navigate() {
        if let pendingSession { store.openSession(pendingSession) }
        else { store.newConversation(); composerFocused = true }
    }
}
