import SwiftUI

@MainActor @Observable final class RemoteAccessSettings {
    static let defaultRelay = "wss://relay.numbersoffice.com"
    let api: AgentAPI
    var relay = defaultRelay
    private(set) var enabled = false
    private(set) var status: AgentJSON = .null
    private(set) var saving = false
    private(set) var loaded = false
    var error: String?
    private var revision = 0

    init(api: AgentAPI) { self.api = api }

    var connection: String {
        guard enabled else { return "Disconnected" }
        if saving { return "Connecting" }
        switch status["connectionStatus"].string {
        case "connected": return "Connected"
        case "connecting": return "Connecting"
        case "relayNotFound": return "Relay not found"
        default: return "Disconnected"
        }
    }
    var connectionColor: Color {
        switch connection {
        case "Connected": .green
        case "Connecting": .yellow
        default: .red
        }
    }
    func refresh() async throws {
        guard !saving else { return }
        let version = revision
        let value = try await api.get("/v1/remote")
        guard version == revision, !saving else { return }
        status = value
        if !loaded {
            relay = Self.address(value)
            enabled = value["enabled"].bool
            loaded = true
        }
    }
    private static func address(_ value: AgentJSON) -> String {
        let saved = value["relay"].string ?? ""
        return saved.isEmpty ? defaultRelay : saved
    }
    func save(enabled requested: Bool? = nil) async {
        guard loaded, !saving else { return }
        let targetEnabled = requested ?? enabled
        // Turning off must work even when the unfinished address is invalid.
        let address = requested == false ? Self.address(status) : relay.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetRelay = address.isEmpty ? Self.defaultRelay : address
        guard targetEnabled != status["enabled"].bool || targetRelay != Self.address(status) else {
            relay = targetRelay
            return
        }
        saving = true
        revision += 1
        enabled = targetEnabled
        error = nil
        defer { saving = false }
        do {
            status = try await api.request("PUT", "/v1/remote", .object([
                "relay": .string(targetRelay), "enabled": .bool(targetEnabled),
                "localDevelopment": .bool(status["localDevelopment"].bool)
            ]))
            enabled = status["enabled"].bool
            relay = Self.address(status)
        } catch {
            // No mutation retry: reconcile an uncertain acknowledgement by reading state.
            self.error = error.localizedDescription
            if let current = try? await api.get("/v1/remote") { status = current }
            enabled = status["enabled"].bool
            relay = Self.address(status)
        }
    }
}
