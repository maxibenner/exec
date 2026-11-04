import AppKit
import SwiftUI

struct ToolApprovalView: View {
    let approval: ToolExecutor.Approval
    let executor: ToolExecutor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(approval.kind == .shell ? "Run shell command?" : "Apply file edit?").font(.headline)
            Text(verbatim: approval.directory.path).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(approval.directory.path).textSelection(.enabled)
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
                Button("Deny") { executor.resolveApproval(id: approval.id, approved: false) }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Approve Once") { executor.resolveApproval(id: approval.id, approved: true) }
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
        guard approval.kind == .edit else { return AttributedString(approval.content) }
        var result = AttributedString()
        let lines = approval.content.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            var text = AttributedString(String(line))
            if line.hasPrefix("+") && !line.hasPrefix("+++") { text.backgroundColor = Color.green.opacity(0.12) }
            if line.hasPrefix("-") && !line.hasPrefix("---") { text.backgroundColor = Color.red.opacity(0.1) }
            result.append(text)
            if index < lines.count - 1 { result.append(AttributedString("\n")) }
        }
        return result
    }
}
