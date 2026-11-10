import SwiftUI

/// Reserve the same space when running, awaiting approval, or finished. The
/// native spinner's intrinsic size must not change the surrounding header.
struct ToolActivityIndicator: View {
    let isRunning: Bool
    var isAwaitingApproval = false
    let label: String

    var body: some View {
        Color.clear
            .frame(width: 16, height: 16)
            .overlay {
                if isAwaitingApproval {
                    Image(systemName: "hand.raised")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Awaiting approval")
                } else if isRunning {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(label)
                }
            }
    }
}
