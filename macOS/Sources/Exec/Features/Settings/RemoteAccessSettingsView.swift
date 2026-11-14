import SwiftUI
import CoreImage.CIFilterBuiltins

struct RemoteAccessSettingsView: View {
    let api: AgentAPI
    private static let defaultRelay = "wss://relay.numbersoffice.com"
    @State private var relay = Self.defaultRelay
    @State private var enabled = false
    @State private var localDevelopment = false
    @State private var status: AgentJSON = .null
    @State private var invitation: AgentJSON?
    @State private var error: String?
    @State private var busy = false
    @State private var revoking: String?
    private var invitationText: String? {
        guard let invitation, let data = try? JSONEncoder().encode(invitation) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    var body: some View {
        Form {
            Section {
                Toggle("Remote access", isOn: $enabled)
                LabeledContent("Status", value: status["connected"].bool ? "Connected" : "Disconnected")
            } footer: {
                Text("Exec must remain open and the Mac awake.")
            }
            Section {
                TextField("Relay", text: $relay)
            } footer: {
                VStack(alignment: .leading, spacing: 12) {
                    Text("You can host your own relay as a docker container. Find the code on [Github](https://github.com/maxibenner/exec/tree/main/relay).")
                        .font(.caption).tint(.blue)
                    Button("Save") { perform {
                        status = try await api.request("PUT", "/v1/remote", .object([
                            "relay":.string(relay), "enabled":.bool(enabled), "localDevelopment":.bool(localDevelopment)
                        ]))
                        invitation = nil
                    } }
                    .buttonStyle(.bordered)
                    .foregroundStyle(.primary)
                }
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
                                Button("Copy Pairing Invitation") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(text, forType: .string)
                                }
                                .buttonStyle(.bordered)
                                .foregroundStyle(.primary)
                                Text("Single use. Expires after five minutes. Only share with a device you trust.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
        }
        .formStyle(.grouped)
        .disabled(busy)
        .confirmationDialog("Revoke this device?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Revoke", role: .destructive) {
                guard let id = revoking else { return }; revoking = nil
                perform { status = try await api.request("DELETE", "/v1/remote/devices/\(id)") }
            }
        }
        .task {
            do {
                status = try await api.get("/v1/remote")
                let savedRelay = status["relay"].string ?? ""
                relay = savedRelay.isEmpty ? Self.defaultRelay : savedRelay
                enabled = status["enabled"].bool
                // Preserve existing local configurations without offering plaintext opt-in in the UI.
                localDevelopment = status["localDevelopment"].bool
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    if !busy { status = try await api.get("/v1/remote") }
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
