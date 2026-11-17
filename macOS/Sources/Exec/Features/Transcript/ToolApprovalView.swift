import AppKit
import SwiftUI

struct ToolApprovalView: View {
    let approval: ToolApprovalState.Approval
    let executor: ToolApprovalState
    var canResolve: () -> Bool = { true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.kind == .screenshot ? "Share a screenshot?" : approval.kind == .shell ? "Run shell command?" : approval.kind == .edit ? "Apply file edit?" : "Approve tool action?").font(.headline)
            ScrollView([.horizontal, .vertical]) {
                Text(preview).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(height: previewHeight)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 10) {
                Spacer()
                Button("Deny") {
                    if canResolve() { executor.resolveApproval(id: approval.id, approved: false) }
                }
                .buttonStyle(ApprovalButtonStyle())
                Button("Approve Once") {
                    if canResolve() { executor.resolveApproval(id: approval.id, approved: true) }
                }
                .buttonStyle(ApprovalButtonStyle(prominent: true))
                // Deliberately not the default Return action: approval must be explicit.
            }
        }
        .padding(12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12)) }
        .environment(\.colorScheme, .light)
        .frame(maxWidth: 820)
        .padding(.horizontal, 20).padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private struct ApprovalButtonStyle: ButtonStyle {
        var prominent = false
        @Environment(\.isEnabled) private var isEnabled

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(prominent ? AppColors.blue : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
        }
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
