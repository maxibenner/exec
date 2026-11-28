import ExecTranscript
import SwiftUI

/// Tool-like presentation for local activity, not an executable agent tool.
struct CompactionMessageView: View {
    let status: Message.Status

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 16)
            Text("Compacting").fontWeight(.medium)
            Spacer(minLength: 0)
            ToolActivityIndicator(isRunning: status == .streaming, label: "Compaction active")
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToolCardAppearance.fill, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(ToolCardAppearance.outline)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}
