import SwiftUI
import CoreImage.CIFilterBuiltins

struct RemoteAccessSettingsView: View {
    let api: AgentAPI
    @State private var settings: RemoteAccessSettings
    @FocusState private var relayFocused: Bool
    @State private var invitation: AgentJSON?
    @State private var error: String?
    @State private var busy = false
    @State private var revoking: String?
    private var status: AgentJSON { settings.status }
    init(api: AgentAPI) {
        self.api = api
        _settings = State(initialValue: RemoteAccessSettings(api: api))
    }
    private var invitationText: String? {
        guard let invitation, let data = try? JSONEncoder().encode(invitation) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    var body: some View {
        Form {
            Section {
                Toggle("Remote access", isOn: Binding(get: { settings.enabled }, set: { value in
                    relayFocused = false
                    Task { await settings.save(enabled: value); invitation = nil }
                }))
                TextField("Relay address", text: $settings.relay, prompt: Text(RemoteAccessSettings.defaultRelay))
                    .focused($relayFocused)
                    .background(RelayFocusDismissal(isFocused: relayFocused) { relayFocused = false })
                    .onSubmit { relayFocused = false }
                    .onChange(of: relayFocused) { _, focused in
                        if !focused { Task { await settings.save(); invitation = nil } }
                    }
                LabeledContent("Status") {
                    Text(settings.connection).foregroundStyle(settings.connectionColor)
                }
            } footer: {
                Text("Exec must remain open and the Mac awake. You can host your own relay as a docker container; find the code on [Github](https://github.com/maxibenner/exec/tree/main/relay).")
                    .tint(AppColors.blue)
            }
            if status["enabled"].bool || !status["devices"].array.isEmpty {
                Section {
                    if status["devices"].array.isEmpty {
                        Text("No paired devices").foregroundStyle(.secondary)
                    }
                    ForEach(status["devices"].array, id: \.selfID) { device in
                        HStack {
                            Text(device["name"].string ?? "Device")
                            Spacer()
                            Button("Revoke", role: .destructive) { revoking = device["id"].string }
                        }
                    }
                } header: {
                    Text("Paired Devices")
                } footer: {
                    if status["enabled"].bool {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("Create Pairing QR Code") { perform {
                                invitation = try await api.request("POST", "/v1/remote/invitations", .object([:]))
                            } }
                            .buttonStyle(.bordered)
                            .foregroundStyle(.primary)
                            .disabled(!status["connected"].bool)
                            if let text = invitationText, let image = qr(text) {
                                HStack {
                                    Spacer()
                                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                                        .padding(12).background(.white).accessibilityLabel("Pairing QR code")
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            if let error = error ?? settings.error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
        }
        .formStyle(.grouped)
        .disabled(busy || settings.saving || !settings.loaded)
        .confirmationDialog("Revoke this device?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Revoke", role: .destructive) {
                guard let id = revoking else { return }; revoking = nil
                perform {
                    _ = try await api.request("DELETE", "/v1/remote/devices/\(id)")
                    try await settings.refresh()
                }
            }
        }
        .task {
            do {
                try await settings.refresh()
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    if !busy && !settings.saving {
                        let observedInvitation = invitationText
                        try await settings.refresh()
                        // An older poll must not dismiss a newly created invitation.
                        if !busy, observedInvitation == invitationText, !status["invitationActive"].bool {
                            invitation = nil
                        }
                    }
                    if let expiry = invitation?["expires"].number, expiry <= Date().timeIntervalSince1970 { invitation = nil }
                }
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onDisappear { invitation = nil }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
    private func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output.transformed(by: .init(scaleX: 6, y: 6)), from: output.extent.applying(.init(scaleX: 6, y: 6))) else { return nil }
        return NSImage(cgImage: image, size: .init(width: image.width, height: image.height))
    }
}
private extension AgentJSON { var selfID: String { self["id"].string ?? "" } }
