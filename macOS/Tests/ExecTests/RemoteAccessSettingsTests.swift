import Foundation

@MainActor struct RemoteAccessSettingsTests {
    private func status(_ enabled: Bool, _ connection: String, relay: String = RemoteAccessSettings.defaultRelay) -> AgentJSON {
        .object(["enabled": .bool(enabled), "connectionStatus": .string(connection), "relay": .string(relay)])
    }
    func savesOnCommitAndDisablesWithInvalidDraft() async throws {
        let transport = FakeAgentTransport()
        try await transport.reply("/v1/remote", status(false, "disconnected", relay: ""))
        let settings = RemoteAccessSettings(api: AgentAPI(transport: transport))
        try await settings.refresh()
        try expect(settings.relay == RemoteAccessSettings.defaultRelay)
        try await transport.reply("/v1/remote", status(true, "connecting"))
        await settings.save(enabled: true)
        try expect(settings.enabled && settings.connection == "Connecting")
        for (state, label) in [("connected", "Connected"), ("relayNotFound", "Relay not found"), ("disconnected", "Disconnected")] {
            try await transport.reply("/v1/remote", status(true, state))
            try await settings.refresh()
            try expect(settings.connection == label)
        }
        settings.relay = "wss://custom.example"
        try await transport.reply("/v1/remote", status(true, "connecting", relay: settings.relay))
        await settings.save()
        await settings.save() // Repeated focus loss must not write again.
        settings.relay = "unfinished invalid address"
        try await transport.reply("/v1/remote", status(false, "connected", relay: "wss://custom.example"))
        await settings.save(enabled: false)
        try expect(!settings.enabled && settings.connection == "Disconnected")
        let writes = await transport.requests.filter { $0.method == "PUT" }
        try expect(writes.count == 3)
        let body = try JSONDecoder().decode(AgentJSON.self, from: writes.last!.body!)
        try expect(body["relay"].string == "wss://custom.example" && !body["enabled"].bool)
    }
    func failedToggleRevertsWithoutRetry() async throws {
        let transport = FakeAgentTransport()
        try await transport.reply("/v1/remote", status(false, "disconnected"))
        let settings = RemoteAccessSettings(api: AgentAPI(transport: transport))
        try await settings.refresh()
        await transport.fail("/v1/remote")
        await settings.save(enabled: true)
        try expect(!settings.enabled && settings.error != nil)
        let writes = await transport.requests.filter { $0.method == "PUT" }
        try expect(writes.count == 1)
    }
}
