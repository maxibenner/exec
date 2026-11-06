import SwiftUI

struct SettingsView: View {
    let store: ChatLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            TabView {
                accountSection
                    .tabItem { Text("Account") }

                Color.clear
                    .tabItem { Text("General") }
            }
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
