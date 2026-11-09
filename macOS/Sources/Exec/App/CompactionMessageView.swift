import SwiftUI

/// Tool-like presentation for local activity, not an executable agent tool.
struct CompactionMessageView: View {
    let trigger: Message.Compaction
    let status: Message.Status

    private var title: String {
        switch status {
        case .streaming: "Compacting context"
        case .complete: "Context compacted"
        case .interrupted: "Compaction interrupted"
        case .failed: "Compaction failed"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 16)
            Text(title).fontWeight(.medium)
            Text(trigger == .automatic ? "Automatic" : "User-triggered")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            switch status {
            case .streaming:
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Compaction active")
            case .complete:
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            case .interrupted:
                Image(systemName: "stop.circle").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
