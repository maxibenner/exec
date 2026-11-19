import Foundation
import Observation
import os

/// Hold a captured response to exercise out-of-order reads without real I/O.
private actor RemoteSettingsTransport: AgentTransport {
    nonisolated let responses = FakeAgentTransport()
    private var pauseNextRead = false
    private var heldRead: CheckedContinuation<Void, Never>?
    var isReadPaused: Bool { heldRead != nil }
    func pauseRead() { pauseNextRead = true }
    func resumeRead() { heldRead?.resume(); heldRead = nil }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        let pause = method == "GET" && pauseNextRead
        if pause { pauseNextRead = false }
        let data = try await responses.request(method, path, body: body)
        if pause { await withCheckedContinuation { heldRead = $0 } }
        return data
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        responses.events(method, path, body: body)
    }
}

@MainActor struct RemoteAccessSettingsCacheTests {
    private func status(_ enabled: Bool, _ connection: String, relay: String = RemoteAccessSettings.defaultRelay,
                        devices: [AgentJSON] = []) -> AgentJSON {
        .object(["enabled": .bool(enabled), "connectionStatus": .string(connection), "relay": .string(relay),
                 "connected": .bool(enabled && connection == "connected"), "localDevelopment": .bool(false),
                 "invitationActive": .bool(false), "devices": .array(devices)])
    }

    func stateSurvivesReentryAndStaysBackendScoped() async throws {
        let suite = "exec-remote-settings-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = FakeAgentTransport()
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        defer { library.closePresentations() }
        let first = RemoteAccessSettingsView(settings: library.remoteAccessSettings)
        try expect(!first.settings.loaded && !first.settings.enabled)
        let initialRequests = await transport.requests
        try expect(initialRequests.isEmpty)
        let cached = status(true, "connected", relay: "wss://custom.example", devices: [
            .object(["id": .string("synthetic-device"), "name": .string("Test phone")])
        ])
        try await transport.reply("/v1/remote", cached)
        try await first.settings.refresh()

        // Reconstruct the page, just as switching tabs or reopening Settings does.
        let reopened = RemoteAccessSettingsView(settings: library.remoteAccessSettings)
        try expect(reopened.settings === first.settings)
        try expect(reopened.settings.loaded && reopened.settings.enabled)
        try expect(reopened.settings.status == cached && reopened.settings.connection == "Connected")
        try expect(reopened.settings.relay == "wss://custom.example")
        let cachedRequests = await transport.requests
        try expect(cachedRequests.count == 1) // Cached state is available before another read.
        try await reopened.settings.refresh()
        try expect(reopened.settings.status == cached && reopened.settings.enabled)

        let other = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: FakeAgentTransport())), preferences: preferences)
        defer { other.closePresentations() }
        try expect(!other.remoteAccessSettings.loaded && other.remoteAccessSettings.status == .null)
        try expect(other.remoteAccessSettings !== reopened.settings)
    }

    func refreshPublishesOnlyChangesAndPreservesRelayDraft() async throws {
        let transport = FakeAgentTransport()
        let settings = RemoteAccessSettings(api: AgentAPI(transport: transport))
        let initial = status(true, "connected")
        try await transport.reply("/v1/remote", initial)
        try await settings.refresh()
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = settings.status; _ = settings.enabled; _ = settings.relay; _ = settings.loaded
        } onChange: { changed.withLock { $0 = true } }
        try await settings.refresh()
        try expect(!changed.withLock { $0 })

        let fresh = status(false, "disconnected", relay: "wss://updated.example")
        try await transport.reply("/v1/remote", fresh)
        try await settings.refresh()
        try expect(changed.withLock { $0 })
        try expect(settings.status == fresh && !settings.enabled && settings.connection == "Disconnected")
        try expect(settings.relay == "wss://updated.example")
        settings.relay = "unfinished relay draft"
        let newer = status(true, "connecting", relay: "wss://another.example")
        try await transport.reply("/v1/remote", newer)
        try await settings.refresh()
        try expect(settings.status == newer && settings.enabled && settings.connection == "Connecting")
        try expect(settings.relay == "unfinished relay draft")
        let requests = await transport.requests
        try expect(requests.allSatisfy { $0.method == "GET" })
    }

    func readFailuresPreserveCacheAndAllowRecovery() async throws {
        let transport = FakeAgentTransport()
        let settings = RemoteAccessSettings(api: AgentAPI(transport: transport))
        await transport.failNext("/v1/remote")
        do {
            try await settings.refresh()
            throw CheckFailure(description: "Initial read must surface its failure")
        } catch is ExecError {}
        try expect(!settings.loaded && !settings.enabled && settings.status == .null)
        await settings.save(enabled: true) // Never mutate before a successful first read.
        let cached = status(true, "connected", relay: "wss://cached.example")
        try await transport.reply("/v1/remote", cached)
        try await settings.refresh()
        await transport.failNext("/v1/remote")
        do {
            try await settings.refresh()
            throw CheckFailure(description: "Refresh must surface its failure")
        } catch is ExecError {}
        try expect(settings.loaded && settings.enabled && settings.status == cached)
        try expect(settings.relay == "wss://cached.example" && settings.connection == "Connected")
        let recovered = status(false, "disconnected")
        try await transport.reply("/v1/remote", recovered)
        try await settings.refresh()
        try expect(settings.status == recovered && !settings.enabled && settings.loaded)
        let requests = await transport.requests
        try expect(requests.allSatisfy { $0.method == "GET" })
    }

    private func waitForRead(_ transport: RemoteSettingsTransport) async throws {
        for _ in 0..<200 {
            if await transport.isReadPaused { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out waiting for a paused remote settings read")
    }

    func olderAndCancelledReadsDoNotReplaceFreshState() async throws {
        let transport = RemoteSettingsTransport()
        let settings = RemoteAccessSettings(api: AgentAPI(transport: transport))
        try await transport.responses.reply("/v1/remote", status(false, "disconnected"))
        await transport.pauseRead()
        let older = Task { try await settings.refresh() }
        try await waitForRead(transport)
        let fresh = status(true, "connected", relay: "wss://fresh.example")
        try await transport.responses.reply("/v1/remote", fresh)
        try await settings.refresh()
        await transport.resumeRead()
        try await older.value
        try expect(settings.loaded && settings.enabled && settings.status == fresh)

        try await transport.responses.reply("/v1/remote", status(false, "disconnected"))
        await transport.pauseRead()
        let cancelled = Task { try await settings.refresh() }
        try await waitForRead(transport)
        cancelled.cancel() // A disappearing page must not publish its late response.
        await transport.resumeRead()
        do {
            try await cancelled.value
            throw CheckFailure(description: "Cancelled read must not apply its response")
        } catch is CancellationError {}
        try expect(settings.status == fresh && settings.enabled && settings.relay == "wss://fresh.example")
    }

    func stalePollDoesNotReplaceToggleAcknowledgement() async throws {
        let transport = RemoteSettingsTransport()
        let settings = RemoteAccessSettings(api: AgentAPI(transport: transport))
        try await transport.responses.reply("/v1/remote", status(false, "disconnected"))
        try await settings.refresh()
        await transport.pauseRead()
        let poll = Task { try await settings.refresh() }
        try await waitForRead(transport)
        let acknowledged = status(true, "connecting")
        try await transport.responses.reply("/v1/remote", acknowledged)
        await settings.save(enabled: true)
        await transport.resumeRead()
        try await poll.value
        try expect(settings.enabled && settings.status == acknowledged && !settings.saving && settings.error == nil)
        let writes = await transport.responses.requests.filter { $0.method == "PUT" }
        try expect(writes.count == 1)
    }

    func toggleUsesAcknowledgementAndReconcilesWithoutRetry() async throws {
        let transport = FakeAgentTransport()
        let settings = RemoteAccessSettings(api: AgentAPI(transport: transport))
        try await transport.reply("/v1/remote", status(false, "disconnected"))
        try await settings.refresh()
        await settings.save(enabled: true) // Server acknowledgement, not optimism, is authoritative.
        try expect(!settings.enabled && !settings.saving && settings.error == nil)

        let accepted = status(true, "connecting")
        try await transport.reply("/v1/remote", accepted)
        await transport.failNext("/v1/remote")
        await settings.save(enabled: true) // The PUT fails, but the recovery GET confirms acceptance.
        try expect(settings.enabled && settings.status == accepted && settings.error != nil)
        try await settings.refresh()
        let requests = await transport.requests
        try expect(requests.map(\.method) == ["GET", "PUT", "PUT", "GET", "GET"])
        try expect(requests.allSatisfy { $0.path == "/v1/remote" })
    }
}
