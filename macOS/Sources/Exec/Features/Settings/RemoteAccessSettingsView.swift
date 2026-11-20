import SwiftUI
import CoreImage.CIFilterBuiltins

struct RemoteAccessSettingsView: View {
    @Bindable var settings: RemoteAccessSettings
    @FocusState private var relayFocused: Bool
    @State private var invitation: PairingQRCode?
    @State private var error: String?
    @State private var busy = false
    @State private var revoking: String?
    private var api: AgentAPI { settings.api }
    private var status: AgentJSON { settings.status }
    var body: some View {
        Form {
            Section {
                Toggle("Remote access", isOn: Binding(get: { settings.enabled }, set: { value in
                    relayFocused = false
                    Task { await settings.save(enabled: value); invitation = nil }
                }))
                .tint(AppColors.systemAccent).accentColor(AppColors.systemAccent)
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
                Text("Exec must remain open and the Mac awake. The default relay is shared and provided as a courtesy. For increased usage consider [hosting your own](https://github.com/maxibenner/exec/tree/main/relay).")
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
                            Button("Revoke") { revoking = device["id"].string }
                        }
                    }
                } header: {
                    Text("Paired Devices")
                } footer: {
                    if status["enabled"].bool {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("Create Pairing QR Code") { perform {
                                let response = try await api.request("POST", "/v1/remote/invitations", .object([:]))
                                invitation = try PairingQRCode(response)
                            } }
                            .buttonStyle(.bordered)
                            .disabled(!status["connected"].bool)
                        }
                    }
                }
            }
            if let error = error ?? settings.error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
        }
        .formStyle(.grouped)
        .disabled(busy || settings.saving || !settings.loaded || invitation != nil)
        .accessibilityHidden(invitation != nil)
        .overlay {
            if let code = invitation {
                ZStack {
                    Color.black.opacity(0.3)
                        .contentShape(Rectangle())
                        .onTapGesture { invitation = nil }
                        .accessibilityHidden(true)

                    PairingQRCodePopup(code: code) { invitation = nil }
                }
            }
        }
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
                        let observedInvitation = invitation?.text
                        try await settings.refresh()
                        // An older poll must not dismiss a newly created invitation.
                        if !busy, observedInvitation == invitation?.text, !status["invitationActive"].bool {
                            invitation = nil
                        }
                    }
                    if let expiry = invitation?.expires, expiry <= Date().timeIntervalSince1970 { invitation = nil }
                }
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onDisappear { invitation = nil }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil
        Task { defer { busy = false }; do { try await action() } catch { self.error = error.localizedDescription } }
    }
}

// Prepare both before presenting; redraws must not re-encode the invitation or replace its image.
struct PairingQRCode {
    let text: String
    let image: NSImage
    let expires: TimeInterval?

    init(_ invitation: AgentJSON) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(invitation)
        let filter = CIFilter.qrCodeGenerator(); filter.message = data; filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output.transformed(by: .init(scaleX: 6, y: 6)), from: output.extent.applying(.init(scaleX: 6, y: 6))) else {
            throw ExecError("The pairing QR code could not be generated.")
        }
        text = String(decoding: data, as: UTF8.self)
        self.image = NSImage(cgImage: image, size: .init(width: image.width, height: image.height))
        expires = invitation["expires"].number
    }
}
private extension AgentJSON { var selfID: String { self["id"].string ?? "" } }
