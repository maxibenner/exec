import SwiftUI

/// Standard macOS account list. Removing and adding a provider is the only
/// credential replacement flow; credential entry stays in a transient sheet.
struct ProviderSettingsView: View {
    let store: ChatLibrary
    @State private var selection: String?
    @State private var adding: ProviderConnection?
    private let rowHeight: CGFloat = 48

    private var connected: [ProviderConnection] { store.connections.filter { $0.account != nil } }
    private var available: [ProviderConnection] { store.connections.filter { $0.account == nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if connected.isEmpty {
                    Text("No providers connected").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).frame(height: 36)
                } else {
                    providerList
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            providerControls
            Spacer(minLength: 0)
        }
        .padding(20)
        .disabled(store.accountBusy || !store.canNavigate)
        .onChange(of: connected.map(\.id)) { _, ids in
            if !ids.contains(selection ?? "") { selection = ids.first }
        }
        .sheet(item: $adding) { connection in
            ProviderKeySheet(providerName: connection.name, canConnect: !store.accountBusy && store.canNavigate) { key in
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
        List(connected, selection: $selection) { connection in
            HStack(spacing: 10) {
                Image(systemName: connection.authentication == .apiKey ? "key" : "person.crop.circle")
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.name)
                    if let account = connection.account {
                        Text(verbatim: account).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .listRowInsets(EdgeInsets())
            .tag(connection.id)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contentMargins(.vertical, 4, for: .scrollContent)
        .frame(height: CGFloat(connected.count) * rowHeight + 8)
    }

    private var providerControls: some View {
        HStack(spacing: 12) {
            ControlGroup {
                Menu {
                    ForEach(available) { connection in
                        Button(connection.name) {
                            if connection.authentication == .apiKey { adding = connection }
                            else { store.connect(providerID: connection.id) }
                        }
                    }
                } label: { Image(systemName: "plus").frame(width: 16, height: 18) }
                .menuIndicator(.visible)
                .disabled(available.isEmpty)
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
            Spacer()
        }
        .controlSize(.small)
    }

}

struct ProviderKeySheet: View {
    let providerName: String
    var canConnect = true
    let connect: (String) -> Void
    @State private var key = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect \(providerName)").font(.headline)
            SecureField("API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .autocorrectionDisabled()
                .accessibilityLabel("API key")
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { key = ""; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    guard canConnect else { return }
                    let credential = key
                    key = ""
                    dismiss()
                    connect(credential)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { focused = true }
        .onDisappear { key = "" }
    }
}
