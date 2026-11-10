import SwiftUI

/// Standard macOS account list. Removing and adding a provider is the only
/// credential replacement flow; credential entry stays in a transient sheet.
struct ProviderSettingsView: View {
    let store: ChatLibrary
    @State private var selection: String?
    @State private var adding: ProviderConnection?

    private var connected: [ProviderConnection] { store.connections.filter { $0.account != nil } }
    private var available: [ProviderConnection] { store.connections.filter { $0.account == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if connected.isEmpty {
                    Text("No providers connected").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(12)
                } else {
                    providerList
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            providerControls
                .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(.background)
        .disabled(store.accountBusy || !store.canNavigate)
        .onChange(of: connected.map(\.id)) { _, ids in
            if !ids.contains(selection ?? "") { selection = ids.first }
        }
        .sheet(item: $adding) { connection in
            ProviderConnectionSheet(providerName: connection.name, authentication: connection.authentication,
                                    canConnect: !store.accountBusy && store.canNavigate) { key in
                store.connect(providerID: connection.id, credential: key)
            }
        }
        .alert("Provider Connection", isPresented: Binding(
            get: { store.connectionError != nil },
            set: { if !$0 { store.connectionError = nil } }
        )) {
            Button("OK", role: .cancel) { store.connectionError = nil }
        } message: {
            Text(store.connectionError ?? "")
        }
    }

    private var providerList: some View {
        // This short account list sizes itself from its rows, including padding.
        // There is no scroll container or separate height to keep in sync.
        VStack(spacing: 0) {
            ForEach(connected) { connection in
                Button { selection = connection.id } label: {
                    HStack(spacing: 10) {
                        Image(systemName: connection.authentication == .apiKey ? "key" : "person.crop.circle")
                            .frame(width: 24)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(connection.name)
                            if let account = connection.account {
                                Text(verbatim: account).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ProviderRowButtonStyle())
                .background(selection == connection.id ? Color.primary.opacity(0.08) : Color.clear)
                .accessibilityAddTraits(selection == connection.id ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connected providers")
    }

    private var addProviderLabel: some View {
        Image(systemName: "plus").frame(width: 16, height: 18)
    }

    private var providerControls: some View {
        HStack {
            Spacer(minLength: 0)
            ControlGroup {
                Group {
                    if available.isEmpty {
                        // A disabled Menu in a ControlGroup keeps its enabled appearance.
                        // Use the same native button state as the remove segment instead.
                        Button {} label: { addProviderLabel }
                            .disabled(true)
                    } else {
                        Menu {
                            ForEach(available) { connection in
                                Button(connection.name) { adding = connection }
                            }
                        } label: { addProviderLabel }
                        .menuIndicator(.hidden)
                    }
                }
                .help("Add Provider")
                .accessibilityLabel("Add Provider")
                Button {
                    guard let selection else { return }
                    store.disconnect(providerID: selection)
                } label: { Image(systemName: "minus").frame(width: 16, height: 18) }
                .disabled(!connected.contains { $0.id == selection })
                .help("Remove Provider")
                .accessibilityLabel("Remove Provider")
            }
            .fixedSize()
        }
        .controlSize(.small)
    }

}

/// Keep row selection separate from transient button press feedback.
private struct ProviderRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

struct ProviderConnectionSheet: View {
    let providerName: String
    var authentication: ProviderConnection.Authentication = .apiKey
    var canConnect = true
    let connect: (String?) -> Void
    @State private var key = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect \(providerName)").font(.headline)
            if authentication == .apiKey {
                SecureField("API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .accessibilityLabel("API key")
            } else {
                Text("Continue in your browser to sign in to \(providerName).")
            }
            Text("Exec stores your provider sign-ins and API keys securely in macOS Keychain so you can stay connected. macOS may ask for permission to save or access these credentials. Exec does not request passwords saved by other apps.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { key = ""; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(authentication == .apiKey ? "Connect" : "Continue") {
                    guard canConnect else { return }
                    let credential = authentication == .apiKey ? key : nil
                    key = ""
                    dismiss()
                    connect(credential)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect || (authentication == .apiKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { focused = authentication == .apiKey }
        .onDisappear { key = "" }
    }
}
