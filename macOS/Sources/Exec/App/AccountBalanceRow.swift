import SwiftUI

struct AccountBalanceRow: View {
    let store: ChatLibrary
    let providerID: String

    var body: some View {
        let balances = store.accountBalance(for: providerID)
        Group {
            if balances.isEmpty {
                LabeledContent("Remaining balance", value: "Unavailable")
            } else {
                ForEach(Array(balances.enumerated()), id: \.offset) { _, balance in
                    LabeledContent("Remaining balance") {
                        Text(balance.amount.formatted(.currency(code: balance.currency).precision(.fractionLength(2...6))))
                            .monospacedDigit()
                    }
                }
            }
        }
        .task(id: store.settingsTab == .usage && !store.authenticating) {
            guard store.settingsTab == .usage else { return }
            await store.refreshAccountBalance(for: providerID)
        }
    }
}
