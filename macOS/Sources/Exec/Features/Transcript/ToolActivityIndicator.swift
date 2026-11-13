import SwiftUI

/// Reserve the same space for active and finished compaction rows. The
/// native spinner's intrinsic size must not change the surrounding header.
struct ToolActivityIndicator: View {
    let isRunning: Bool
    let label: String

    var body: some View {
        Color.clear
            .frame(width: 16, height: 16)
            .overlay {
                if isRunning {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(label)
                }
            }
    }
}
