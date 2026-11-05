import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatLibrary
    @State private var pendingDeletion: SessionSummary?
    @State private var confirmingDeletion = false
    @FocusState private var composerFocused: Bool
    @State private var errorHeight: CGFloat = 20

    var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store, open: { requestNavigation(to: $0) }, delete: {
                guard store.canNavigate, !store.isSessionRunning($0.id) else { return }
                pendingDeletion = $0; confirmingDeletion = true
            })
        } detail: {
            VStack(spacing: 0) {
                TranscriptView(messages: store.messages, sessionID: store.currentSessionID)
                if let approval = store.tools.pendingApproval {
                    let executor = store.tools
                    Divider()
                    ToolApprovalView(approval: approval, executor: executor,
                                     canResolve: { !store.navigating && store.tools === executor })
                        .disabled(store.navigating).layoutPriority(1)
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
                    .disabled(store.authenticating).allowsHitTesting(store.canNavigate)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .confirmationDialog("Delete this conversation?", isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button("Delete Conversation", role: .destructive) {
                if let session = pendingDeletion { store.deleteSession(session.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(pendingDeletion?.title ?? "")” will be permanently deleted from this Mac. Files changed by its tools will not be undone.")
        }
        .task { store.restore(); composerFocused = true }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                WorkspaceBar(store: store)
                if !store.models.isEmpty || !store.selectedModel.isEmpty {
                    AutoApprovalToggle(store: store)
                    Picker("Model", selection: $store.selectedModel) {
                        ForEach(store.models) { Text($0.name).tag($0.id) }
                        if !store.selectedModel.isEmpty && !store.models.contains(where: { $0.id == store.selectedModel }) {
                            Text(store.selectedModel).tag(store.selectedModel)
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).controlSize(.small)
                    .frame(maxWidth: 180, alignment: .trailing).fixedSize(horizontal: true, vertical: false)
                    .disabled(store.isWorking).allowsHitTesting(!store.busy)
                    .accessibilityLabel("Model")
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message", text: $store.draft, axis: .vertical)
                    .lineLimit(1...8).textFieldStyle(.plain).font(.body)
                    .focused($composerFocused)
                    .disabled(store.isWorking && !store.isSending).allowsHitTesting(!store.navigating)
                    .accessibilityLabel("Message")
                    .onSubmit { store.send() }
                    .padding(.vertical, 8)
                HStack(alignment: .center, spacing: 12) {
                    if store.isWorking {
                        if store.tools.pendingApproval == nil {
                            ProgressView().controlSize(.small).frame(width: 16, height: 16).accessibilityLabel("Working")
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
                            .disabled(store.busy || store.account == nil || store.selectedModel.isEmpty || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .frame(height: 32)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(composerFocused ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.18), lineWidth: 1)
        }
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
        guard store.canNavigate, id == nil || id != store.currentSessionID else { return }
        if let id { store.openSession(id) }
        else { store.newConversation(); composerFocused = true }
    }
}
