import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatLibrary
    @FocusState private var composerFocused: Bool
    @State private var errorHeight: CGFloat = 20

    var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store, open: { requestNavigation(to: $0) }, delete: {
                guard store.canNavigate, !store.isSessionRunning($0.id) else { return }
                store.deleteSession($0.id)
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
                ChatComposer(store: store, focused: $composerFocused)
            }
            // A conversation owns its transient controls and scroll state. Do not morph
            // the previous conversation's view tree into the newly selected one.
            .id(ObjectIdentifier(store.current))
            .transaction(value: ObjectIdentifier(store.current)) { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
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
        .task { store.restore(); composerFocused = true }
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
