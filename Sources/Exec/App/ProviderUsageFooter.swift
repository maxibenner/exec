import SwiftUI

/// A pinned, provider-neutral account summary, separate from conversation context usage.
struct ProviderUsageFooter: View {
    let providerName: String
    let usage: AccountUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: providerName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                AccountUsageLabel(usage: usage)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(providerName) remaining usage")
    }
}
