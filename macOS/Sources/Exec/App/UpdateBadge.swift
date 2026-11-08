import SwiftUI

struct UpdateBadge: View {
    let canCheckForUpdates: Bool
    let update: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: update) {
                Label("Update available", systemImage: "arrow.down.circle")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .disabled(!canCheckForUpdates)
            .accessibilityLabel("Update available")
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss update notification")
            .padding(.trailing, 2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}
