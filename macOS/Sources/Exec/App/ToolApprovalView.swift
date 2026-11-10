import AppKit
import SwiftUI

struct ToolApprovalView: View {
    let approval: ToolExecutor.Approval
    let executor: ToolExecutor
    var canResolve: () -> Bool = { true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.kind == .screenshot ? "Share a screenshot?" : approval.kind == .shell ? "Run shell command?" : "Apply file edit?").font(.headline)
            if approval.kind != .screenshot {
                Text(verbatim: approval.directory.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(approval.directory.path).textSelection(.enabled)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(preview).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(height: previewHeight)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            if approval.kind == .shell {
                Text("Not sandboxed: this command can access files outside the workspace, use the network, or delete data with your user privileges.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Deny") {
                    if canResolve() { executor.resolveApproval(id: approval.id, approved: false) }
                }
                if approval.kind == .screenshot {
                    Button("Always for This Session") {
                        if canResolve() {
                            executor.resolveApproval(id: approval.id, approved: true, allowScreenshotsForSession: true)
                        }
                    }
                }
                Button("Approve Once") {
                    if canResolve() { executor.resolveApproval(id: approval.id, approved: true) }
                }
                    .buttonStyle(.borderedProminent)
                // Deliberately not the default Return action: approval must be explicit.
            }
        }
        .frame(maxWidth: 820)
        .padding(.horizontal, 20).padding(.vertical, 16)
        .frame(maxWidth: .infinity)
    }

    private var previewHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let lines = approval.content.split(separator: "\n", omittingEmptySubsequences: false).count
        return min(approval.kind == .edit ? 220 : 120, max(60, CGFloat(lines) * lineHeight + 20))
    }

    private var preview: AttributedString {
        approval.kind == .edit ? DiffView.highlighted(approval.content) : AttributedString(approval.content)
    }
}
