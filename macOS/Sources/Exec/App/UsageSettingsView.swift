import SwiftUI

struct UsageSettingsView: View {
    let store: ChatLibrary
    private var connected: [ProviderConnection] { store.connectedProviders }

    var body: some View {
        Form {
            if connected.isEmpty {
                Section { Text("No providers connected").foregroundStyle(.secondary) }
            }
            ForEach(connected) { connection in
                Section(connection.name) {
                    if connection.id == store.usageConnection?.id {
                        AccountUsageLabel(usage: store.displayedAccountUsage, fetchedAt: store.accountUsageFetchedAt)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("\(connection.name) remaining usage")
                    } else {
                        Text("Usage unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
