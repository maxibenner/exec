import AppKit
import SwiftUI

struct ChatView: View {
    @Bindable var store: ChatLibrary
    @FocusState private var composerFocused: Bool
    @State private var errorHeight: CGFloat = 20
    @State private var composerHeight: CGFloat = 140

    var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store, open: { requestNavigation(to: $0) }, delete: {
                guard store.canNavigate, !store.isSessionRunning($0.id) else { return }
                store.deleteSession($0.id)
            })
        } detail: {
            ZStack(alignment: .bottom) {
                ZStack {
                    ForEach(store.openConversations) { conversation in
                        ResidentTranscript(conversation: conversation, isActive: conversation === store.current, bottomInset: composerHeight)
                            .id(conversation.currentSessionID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 0) {
                    if let approval = store.tools.pendingApproval {
                        let executor = store.tools
                        ToolApprovalView(approval: approval, executor: executor,
                                         canResolve: { !store.navigating && store.tools === executor })
                            .id(approval.id)
                            .disabled(store.navigating).layoutPriority(1)
                            .background(.background)
                    }
                    if let error = store.error { errorView(error).background(.background) }
                    ChatComposer(store: store, focused: $composerFocused)
                        .id(ObjectIdentifier(store.current))
                        .disabled(store.navigating)
                }
                // Keep every overlay background and control out of the native
                // scrollbar lane, including when overlay scrollers expand on hover.
                .padding(.trailing, NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
            // Keep per-conversation scroll state; only the selected transcript mounts views.
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
        .onExitCommand { if store.isWorking { store.stop() } }
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
        guard store.canNavigate, id == nil || id != store.sidebarSelectionID else { return }
        if let id { store.openSession(id) }
        else { store.newConversation(); composerFocused = true }
    }
}

/// Keep only lightweight presentation state for inactive conversations. Their runners,
/// drafts and provider context remain resident in ChatLibrary, independently of the UI.
private struct ResidentTranscript: View {
    let conversation: ChatStore
    let isActive: Bool
    let bottomInset: CGFloat
    @State private var presentation = TranscriptState()

    var body: some View {
        if isActive {
            TranscriptView(messages: conversation.messages, state: presentation, bottomInset: bottomInset)
        }
    }
}
