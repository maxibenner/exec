import SwiftUI

/// A pinned, provider-neutral account summary, separate from conversation context usage.
struct ProviderUsageFooter: View {
    let providerName: String
    let usage: AccountUsage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            AccountUsageLabel(usage: usage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(providerName) remaining usage")
    }
}
