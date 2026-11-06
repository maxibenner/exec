import SwiftUI

struct SettingsView: View {
    let store: ChatLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .account

    private enum SettingsTab: String, CaseIterable {
        case account = "Account"
        case general = "General"
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Picker("Settings section", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)

            GroupBox {
                switch selectedTab {
                case .account:
                    accountSection
                case .general:
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(width: 480, height: 300)
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let account = store.account {
                Label {
                    Text(verbatim: account).textSelection(.enabled)
                } icon: {
                    Image(systemName: "person.crop.circle")
                }

                HStack {
                    Button("Refresh Models", action: store.restore)
                    Button("Reconnect", action: store.connect)
                    Spacer()
                    Button("Sign Out", role: .destructive, action: store.disconnect)
                }
            } else {
                Button(store.connectionTitle, action: store.connect)
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(store.accountBusy || !store.canNavigate)
    }
}
