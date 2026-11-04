import SwiftUI

struct ToolApprovalView: View {
    let approval: ToolExecutor.Approval
    let executor: ToolExecutor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(approval.kind == .shell ? "Run shell command?" : "Apply file edit?").font(.headline)
            Text(approval.directory.path).font(.caption).lineLimit(1).truncationMode(.middle)
                .help(approval.directory.path).textSelection(.enabled)
            ScrollView {
                Text(approval.content).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: approval.kind == .edit ? 240 : 120)
            if approval.kind == .shell {
                Text("Not sandboxed: this command can access files outside the workspace, use the network, or delete data with your user privileges.")
                    .font(.callout)
            }
            HStack {
                Spacer()
                Button("Deny") { executor.resolveApproval(id: approval.id, approved: false) }
                Button("Approve Once") { executor.resolveApproval(id: approval.id, approved: true) }
            }
        }
        .padding()
    }
}
