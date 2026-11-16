import AppKit
import SwiftUI

/// Shared by the main detail pane and detached windows; no restoration or model
/// requests are triggered by mounting or moving this view.
struct ConversationView: View {
    @State private var panel: ChatPanel
    let presentation: TranscriptState
    let showsNavigationError: Bool
    let openRelatedSession: ((UUID) -> Void)?
    @FocusState.Binding var composerFocused: Bool
    @State private var errorHeight: CGFloat = 20
    @State private var composerHeight: CGFloat = 140

    init(library: ChatLibrary, conversation: ChatStore, presentation: TranscriptState,
         focused: FocusState<Bool>.Binding, showsNavigationError: Bool = false, openRelatedSession: ((UUID) -> Void)? = nil) {
        self.init(panel: ChatPanel(library: library, conversation: conversation), presentation: presentation,
                  focused: focused, showsNavigationError: showsNavigationError, openRelatedSession: openRelatedSession)
    }

    init(panel: ChatPanel, presentation: TranscriptState, focused: FocusState<Bool>.Binding,
         showsNavigationError: Bool = false, openRelatedSession: ((UUID) -> Void)? = nil) {
        _panel = State(initialValue: panel)
        _composerFocused = focused
        self.presentation = presentation
        self.showsNavigationError = showsNavigationError
        self.openRelatedSession = openRelatedSession
    }

    private var children: [SessionSummary] { panel.library.childSessions(of: panel.current.currentSessionID) }
    private func openRelated(_ id: UUID) {
        if let openRelatedSession { openRelatedSession(id) }
        else { panel.library.openSession(id) }
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
        .onChange(of: children, initial: true) { _, sessions in
            presentation.delegatedSessions = sessions
        }
        .onAppear {
            let library = panel.library
            let open = openRelatedSession
            presentation.openRelatedSession = { [weak library] id in
                if let open { open(id) } else { library?.openSession(id) }
            }
        }
        .onDisappear { presentation.openRelatedSession = nil }
        .onExitCommand { if panel.isWorking { panel.stop() } }
        .background(WindowReference { panel.window = $0 })
        .background(ChatWindowTitle(title: panel.title))
        .navigationTitle(panel.title)
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
        ZStack(alignment: .bottom) {
            // Keep the scroll surface full-height. The measured overlay height is
            // trailing document space, not a clipped viewport or safe-area inset.
            TranscriptView(messages: panel.current.messages, state: presentation, bottomInset: composerHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                if let parent = panel.current.summary?.parent,
                   panel.library.sessionList.contains(where: { $0.id == parent.sessionId }) {
                    Button { openRelated(parent.sessionId) } label: {
                        Label("Open managing session", systemImage: "arrow.turn.up.left")
                    }
                    .buttonStyle(.link).padding(8).disabled(!panel.canNavigate)
                }
                if !children.isEmpty {
                    Menu {
                        ForEach(children) { child in
                            Button(child.title) { openRelated(child.id) }
                        }
                    } label: { Label("Sub-agents", systemImage: "person.crop.square.on.square") }
                    .menuStyle(.borderlessButton).fixedSize().padding(8).disabled(!panel.canNavigate)
                }
                // Child approvals remain actionable even when their tool card is offscreen.
                ForEach(children.filter(\.awaitingApproval)) { child in
                    Button { openRelated(child.id) } label: {
                        Label("Review sub-agent approval", systemImage: "hand.raised")
                    }
                    .buttonStyle(.link).padding(8).disabled(!panel.canNavigate)
                }
                if let approval = panel.current.tools.pendingApproval {
                    let executor = panel.current.tools
                    ToolApprovalView(approval: approval, executor: executor,
                                     canResolve: { panel.canNavigate && panel.current.tools === executor })
                        .id(approval.id)
                        .disabled(!panel.canNavigate).layoutPriority(1)
                        .background(.background)
                }
                if let error { errorView(error).background(.background) }
                ChatComposer(store: panel, focused: $composerFocused)
                    .disabled(panel.navigating)
            }
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
