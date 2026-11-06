import AppKit
import SwiftUI

/// Shared by the main detail pane and detached windows; no restoration or model
/// requests are triggered by mounting or moving this view.
struct ConversationView: View {
    @State private var panel: ChatPanel
    let presentation: TranscriptState
    let showsNavigationError: Bool
    @State private var errorHeight: CGFloat = 20
    @State private var composerHeight: CGFloat = 140

    init(library: ChatLibrary, conversation: ChatStore, presentation: TranscriptState,
         showsNavigationError: Bool = false) {
        _panel = State(initialValue: ChatPanel(library: library, conversation: conversation))
        self.presentation = presentation
        self.showsNavigationError = showsNavigationError
    }

    private var error: String? { showsNavigationError ? panel.library.error : panel.current.error }

    var body: some View {
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
                ChatComposer(store: panel)
                    .disabled(panel.navigating)
            }
            .padding(.trailing, presentation.trailingInset)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        .frame(minWidth: 460, minHeight: 480)
        .onExitCommand { if panel.isWorking { panel.stop() } }
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
