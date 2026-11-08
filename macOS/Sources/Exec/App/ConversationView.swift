import AppKit
import SwiftUI

/// Shared by the main detail pane and detached windows; no restoration or model
/// requests are triggered by mounting or moving this view.
struct ConversationView: View {
    @State private var panel: ChatPanel
    let presentation: TranscriptState
    let showsNavigationError: Bool
    @FocusState.Binding var composerFocused: Bool
    @State private var errorHeight: CGFloat = 20
    @State private var composerHeight: CGFloat = 140

    init(library: ChatLibrary, conversation: ChatStore, presentation: TranscriptState,
         focused: FocusState<Bool>.Binding, showsNavigationError: Bool = false) {
        self.init(panel: ChatPanel(library: library, conversation: conversation), presentation: presentation,
                  focused: focused, showsNavigationError: showsNavigationError)
    }

    init(panel: ChatPanel, presentation: TranscriptState, focused: FocusState<Bool>.Binding,
         showsNavigationError: Bool = false) {
        _panel = State(initialValue: panel)
        _composerFocused = focused
        self.presentation = presentation
        self.showsNavigationError = showsNavigationError
    }

    private var error: String? { showsNavigationError ? panel.library.error : panel.current.error }

    var body: some View {
        Group {
            if panel.hasConversation {
                conversation
            } else if panel.current.isRestoringSession {
                Color.clear
            } else {
                VStack(spacing: 0) {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(spacing: 6) {
                            Text("No Sessions")
                                .font(.headline.bold())
                            Text("Press ⌘T to create one.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Press Command T to create one.")
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let error { errorView(error) }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 480)
        .onExitCommand { if panel.isWorking { panel.stop() } }
        .background(WindowReference { panel.window = $0 })
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
            TranscriptView(messages: panel.current.messages, state: presentation, bottomInset: composerHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                if let approval = panel.current.tools.pendingApproval {
                    let executor = panel.current.tools
                    ToolApprovalView(approval: approval, executor: executor,
                                     canResolve: { panel.canNavigate && panel.current.tools === executor })
                        .id(approval.id)
                        .disabled(!panel.canNavigate).layoutPriority(1)
                        .background(.background)
                }
                if let error { errorView(error).background(.background) }
                ChatComposer(store: panel, overlayScrollerInset: presentation.overlayScrollerInset, focused: $composerFocused)
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
