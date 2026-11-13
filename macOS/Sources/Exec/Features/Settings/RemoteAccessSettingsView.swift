import SwiftUI
import CoreImage.CIFilterBuiltins

struct RemoteAccessSettingsView: View {
    let api: AgentAPI
    @State private var relay = ""
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
                TextField("Relay", text: $relay, prompt: Text("wss://relay.example.com"))
                Toggle("Local development relay", isOn: $localDevelopment)
                    .onChange(of: localDevelopment) { _, local in
                        if local && relay.isEmpty { relay = "ws://127.0.0.1:8787" }
                    }
                Button("Save") { perform {
                    status = try await api.request("PUT", "/v1/remote", .object([
                        "relay":.string(relay), "enabled":.bool(enabled), "localDevelopment":.bool(localDevelopment)
                    ]))
                    invitation = nil
                } }
                if status["enabled"].bool {
                    LabeledContent("Relay", value: status["connected"].bool ? "Connected" : "Disconnected")
                }
            } footer: {
                Text("Remote devices can run tools on this Mac. Exec must remain open and the Mac awake. Production relays require wss://.")
            }
            if status["enabled"].bool {
                Section("Pair a Device") {
                    Button("Create Pairing QR Code") { perform {
                        invitation = try await api.request("POST", "/v1/remote/invitations", .object([:]))
                    } }
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
                        Text("Single use. Expires after five minutes. Only share with a device you trust.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !status["devices"].array.isEmpty {
                Section("Paired Devices") {
                    ForEach(status["devices"].array, id: \.selfID) { device in
                        HStack {
                            Text(device["name"].string ?? "Device")
                            Spacer()
                            Button("Revoke", role: .destructive) { revoking = device["id"].string }
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
                relay = status["relay"].string ?? ""; enabled = status["enabled"].bool; localDevelopment = status["localDevelopment"].bool
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
