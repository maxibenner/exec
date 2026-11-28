import AppKit
import SwiftUI

/// Shared by the main detail pane and detached windows; no restoration or model
/// requests are triggered by mounting or moving this view.
struct ConversationView: View {
    @State private var panel: ChatPanel
    let presentation: TranscriptState
    let showsNavigationError: Bool
    let composerFocusRequest: Int?
    @Binding var composerFocused: Bool
    @State private var errorHeight: CGFloat = 20
    @State private var composerHeight: CGFloat = 140

    init(library: ChatLibrary, conversation: ChatStore, presentation: TranscriptState,
         focused: Binding<Bool>, showsNavigationError: Bool = false,
         composerFocusRequest: Int? = nil) {
        self.init(panel: ChatPanel(library: library, conversation: conversation), presentation: presentation,
                  focused: focused, showsNavigationError: showsNavigationError, composerFocusRequest: composerFocusRequest)
    }

    init(panel: ChatPanel, presentation: TranscriptState, focused: Binding<Bool>,
         showsNavigationError: Bool = false, composerFocusRequest: Int? = nil) {
        _panel = State(initialValue: panel)
        _composerFocused = focused
        self.presentation = presentation
        self.showsNavigationError = showsNavigationError
        self.composerFocusRequest = composerFocusRequest
    }

    private var error: String? { showsNavigationError ? panel.library.error : panel.current.error }

    var body: some View {
        Group {
            if panel.hasConversation {
                conversation
                    .ignoresSafeArea(.container, edges: .top)
            } else if panel.current.isRestoringSession {
                Color.clear
            } else {
                VStack(spacing: 0) {
                    NoSessionsView()
                    if let error { errorView(error) }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 480)
        .onExitCommand { if panel.isWorking { panel.stop() } }
        .background(WindowReference { panel.window = $0 })
        .background(ChatWindowTitle(title: panel.title))
        .navigationTitle(panel.title)
        .toolbar {
            if panel.hasConversation && !panel.current.isSubagent {
                ToolbarItem(placement: .primaryAction) {
                    SessionToolMenu(conversation: panel.current)
                        .disabled(!panel.canNavigate)
                }
            }
        }
        .task(id: panel.shouldChooseInitialWorkspace) {
            // Wait for the owning window and leave the SwiftUI update before
            // presenting a native sheet. A remount must not reopen a cancelled picker.
            guard panel.shouldChooseInitialWorkspace else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            panel.chooseInitialWorkspaceIfNeeded()
        }
    }

    private var conversation: some View {
        // The transcript determines the viewport. A tall queue grows above the
        // composer without making the viewport bigger than the window.
        TranscriptView(messages: panel.current.messages, state: presentation, bottomInset: composerHeight,
                       showsThinkingIndicator: panel.current.showsThinkingIndicator,
                       immediateSendID: panel.current.latestImmediateSendID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: panel.workspace?.root, initial: true) { _, root in
                presentation.workspaceRoot = root
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    let destination = panel.current
                    if !destination.queuedMessages.isEmpty {
                        QueuedMessagesView(messages: destination.queuedMessages,
                                           canCancel: panel.canNavigate && destination.canCancelQueuedInput) { messageID in
                            guard panel.canNavigate, panel.current === destination, destination.canCancelQueuedInput,
                                  destination.queuedMessages.contains(where: { $0.id == messageID }) else { return }
                            destination.cancelQueuedInput(messageID)
                        }
                    }
                    if let approval = destination.tools.pendingApproval {
                        let executor = destination.tools
                        ToolApprovalView(approval: approval, executor: executor,
                                         canResolve: { panel.canNavigate && panel.current.tools === executor })
                            .id(approval.id)
                            .disabled(!panel.canNavigate)
                    }
                    if let error { errorView(error).background(.background) }
                    ChatComposer(store: panel, focused: $composerFocused, focusRequest: composerFocusRequest,
                                 editingState: presentation.composerEditingState)
                        .disabled(panel.navigating)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, presentation.trailingInset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
    }

    private func errorView(_ error: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
            ScrollView {
                Text(verbatim: error).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { errorHeight = $0 }
            }
            .defaultScrollAnchor(.topLeading)
            .frame(height: min(100, max(20, errorHeight)))
            Button {
                if showsNavigationError { panel.library.error = nil }
                else { panel.current.error = nil }
            } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Dismiss error").accessibilityLabel("Dismiss error")
        }
        .padding(12).background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 820).padding(.horizontal, 20).padding(.top, 8)
        .frame(maxWidth: .infinity)
    }
}
