import SwiftUI

/// Tool-like presentation for local activity, not an executable agent tool.
struct CompactionMessageView: View {
    let trigger: Message.Compaction
    let status: Message.Status

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 16)
            Text("Compacting").fontWeight(.medium)
            Text(trigger == .automatic ? "Automatic" : "User-triggered")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if status == .streaming {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Compaction active")
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
