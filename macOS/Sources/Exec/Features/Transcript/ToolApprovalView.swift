import AppKit
import SwiftUI

struct ToolApprovalView: View {
    let approval: ToolApprovalState.Approval
    let executor: ToolApprovalState
    var canResolve: () -> Bool = { true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.kind == .screenshot ? "Share a screenshot?" : approval.kind == .shell ? "Run shell command?" : approval.kind == .edit ? "Apply file edit?" : "Approve tool action?").font(.headline)
            preview
            HStack(spacing: 10) {
                Spacer()
                Button("Deny") {
                    if canResolve() { executor.resolveApproval(id: approval.id, approved: false) }
                }
                .buttonStyle(.bordered)
                // Deliberately not the default Return action: approval must be explicit.
                Button("Approve Once") {
                    if canResolve() { executor.resolveApproval(id: approval.id, approved: true) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)) }
        .frame(maxWidth: 820)
        .padding(.horizontal, 20).padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private var showsPreparedDiff: Bool {
        // A prepared patch starts with file headers; keep a description-only fallback verbatim.
        approval.kind == .edit && approval.content.hasPrefix("--- ")
    }

    private var preview: some View {
        // The shared diff manages horizontal scrolling so the gutter stays put.
        ScrollView(showsPreparedDiff ? .vertical : [.horizontal, .vertical]) {
            if showsPreparedDiff {
                DiffView(source: approval.content, showsPatchHeaders: true)
            } else {
                Text(verbatim: approval.content).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
        .defaultScrollAnchor(.topLeading)
        .frame(height: previewHeight)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var previewHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let lineHeight = showsPreparedDiff ? DiffView.lineHeight : ceil(font.ascender - font.descender + font.leading)
        let lines = approval.content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        return min(approval.kind == .edit ? 220 : 120, max(60, CGFloat(lines) * lineHeight + 20))
    }
}
