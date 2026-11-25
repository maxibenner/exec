import XCTest
import Observation
import os
import ExecRemote
@testable import ExecRemoteStore

@MainActor final class ToolAvailabilityTests: XCTestCase {
    private let model: RemoteJSON = .object(["id": .string("fixture/model")])
    private let settings: RemoteJSON = .object(["searchModel": .string("fixture/search"), "autoApprove": .bool(false)])
    private func host(route: String = "a") throws -> PairedHost {
        let invitation = try RemoteJSON.object([
            "version": .number(1), "relay": .string("wss://example.invalid"),
            "route": .string(String(repeating: route, count: 64)),
            "hostKey": .string(Data(repeating: 0, count: 32).base64EncodedString()),
            "expires": .number(0), "localDevelopment": .bool(false)
        ]).decoded(PairingInvitation.self)
        return PairedHost(invitation: invitation, deviceName: "Availability fixture")
    }
    private func makeStore(_ transport: FakeTransport) throws -> RemoteStore {
        let host = try host()
        return RemoteStore(client: transport, loadHost: { host }, saveHost: { _ in }, forgetHost: {},
                           sleep: { _ in throw CancellationError() })
    }
    private func response(_ available: Bool, reason: String = "Synthetic reason") -> RemoteJSON {
        .object(["shell": .object(["available": .bool(available), "reason": .string(reason)]),
                 "read_file": .object(["available": .bool(true)])])
    }
    private func request(_ store: RemoteStore) -> RemoteStore.ToolAvailabilityRequest {
        store.toolAvailabilityRequest(model: model, settings: settings)
    }
    private func until(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<10_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Availability fixture did not reach the expected state")
        throw RemoteFailure("Test synchronization failed.")
    }

    func testAvailabilityReadDoesNotAdmitMutationOrChangeDefaultsSelectionOrCreateBody() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.connect()
        let library: RemoteJSON = .object(["defaultDisabledTools": .array([.string("shell"), .string("future_tool")]),
                                           "settings": settings])
        store.library = library
        var tools = RemoteSessionCreation.ToolSelection(library: library)
        tools.setEnabled("read_file", false)
        let create = RemoteSessionCreation.body(workspace: "/Fixture", model: model, effort: "", settings: settings, tools: tools)
        let before = await transport.requests.count
        await transport.setAvailability(response(false))
        await transport.holdNextRequest("POST", "/v1/tools/availability")
        let key = request(store)
        let read = Task { await store.refreshToolAvailability(key) }
        try await until { await transport.waitingForRequest }
        XCTAssertFalse(store.hasPendingCommands)
        XCTAssertFalse(store.isCreatingSession)
        XCTAssertTrue(store.canEditSharedSettings)
        XCTAssertTrue(store.toolAvailability(for: key).isEmpty)
        await transport.releaseRequest(); await read.value
        XCTAssertEqual(store.toolAvailability(for: key), ["shell": false, "read_file": true])
        XCTAssertEqual(store.library, library)
        XCTAssertEqual(tools.disabledTools, ["shell", "read_file"])
        XCTAssertEqual(RemoteSessionCreation.body(workspace: "/Fixture", model: model, effort: "", settings: settings, tools: tools), create)
        let bodies = await transport.availabilityBodies
        XCTAssertEqual(bodies, [RemoteSessionCreation.AvailabilityQuery(model: model, settings: settings).body])
        let reads = await Array(transport.requests.dropFirst(before))
        XCTAssertEqual(reads, ["POST /v1/tools/availability"], "No mutation helper or follow-up catalog write/read")
        XCTAssertNil(store.error)
    }

    func testSameContextRefreshKeepsCachedStatusesAndPublishesOnlyBooleanChanges() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.connect()
        let key = request(store)
        await transport.setAvailability(response(false))
        await store.refreshToolAvailability(key)
        let publications = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = store.toolAvailability(for: key)
        } onChange: {
            publications.withLock { $0 += 1 }
        }
        await transport.setAvailability(response(false, reason: "Changed reason only"))
        await transport.holdNextRequest("POST", "/v1/tools/availability")
        let read = Task { await store.refreshToolAvailability(key) }
        try await until { await transport.waitingForRequest }
        XCTAssertEqual(store.toolAvailability(for: key)["shell"], false, "Never blank a usable same-context baseline")
        await transport.releaseRequest(); await read.value
        XCTAssertEqual(publications.withLock { $0 }, 0)
        await transport.setAvailability(response(true))
        await store.refreshToolAvailability(key)
        XCTAssertEqual(publications.withLock { $0 }, 1)
        XCTAssertEqual(store.toolAvailability(for: key)["shell"], true)
        await transport.setAvailability(.null, failure: RemoteFailure("Synthetic read failure"))
        await store.refreshToolAvailability(key)
        XCTAssertEqual(store.toolAvailability(for: key)["shell"], true)
        XCTAssertNil(store.error, "An optional read rejection must not replace the session notice")
        await transport.setAvailability(.null)
        await store.refreshToolAvailability(key)
        XCTAssertEqual(store.toolAvailability(for: key)["shell"], true, "Malformed top-level responses are not successful refreshes")
    }

    func testModelSearchAndBackendChangesAreUnknownAndRejectLateResponses() async throws {
        for change in ["model", "search", "backend"] {
            let transport = FakeTransport(), store = try makeStore(transport)
            await store.connect()
            let original = request(store)
            await transport.setAvailability(response(true))
            await store.refreshToolAvailability(original)
            await transport.holdNextRequest("POST", "/v1/tools/availability", captureResponse: true)
            let late = Task { await store.refreshToolAvailability(original) }
            try await until { await transport.waitingForRequest }
            var nextModel = model, nextSettings = settings
            switch change {
            case "model": nextModel = .object(["id": .string("different/model")])
            case "search": nextSettings = .object(["searchModel": .string("different/search")])
            default: store.host = try host(route: "b")
            }
            let next = store.toolAvailabilityRequest(model: nextModel, settings: nextSettings)
            XCTAssertNotEqual(next, original)
            XCTAssertTrue(store.toolAvailability(for: next).isEmpty, "A different context must not look available")
            await transport.setAvailability(response(false))
            await store.refreshToolAvailability(next)
            await transport.releaseRequest(); await late.value
            XCTAssertEqual(store.toolAvailability(for: next)["shell"], false, change)
            XCTAssertTrue(store.toolAvailability(for: original).isEmpty)
        }
    }

    func testSupersededAndCancelledReadsCannotOverwriteNewerSameContextStatuses() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.connect()
        let key = request(store)
        await transport.setAvailability(response(true))
        await transport.holdNextRequest("POST", "/v1/tools/availability", captureResponse: true)
        let late = Task { await store.refreshToolAvailability(key) }
        try await until { await transport.waitingForRequest }
        await transport.setAvailability(response(false))
        await store.refreshToolAvailability(key)
        await transport.releaseRequest(); await late.value
        XCTAssertEqual(store.toolAvailability(for: key)["shell"], false)
        await transport.setAvailability(response(true))
        await transport.holdNextRequest("POST", "/v1/tools/availability")
        let cancelled = Task { await store.refreshToolAvailability(key) }
        try await until { await transport.waitingForRequest }
        cancelled.cancel()
        await transport.releaseRequest(); await cancelled.value
        XCTAssertEqual(store.toolAvailability(for: key)["shell"], false)
        XCTAssertNil(store.error)
    }

    func testReconnectInvalidatesCachedAndInflightStatuses() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.connect()
        let original = request(store)
        await transport.setAvailability(response(true))
        await store.refreshToolAvailability(original)
        await transport.holdNextRequest("POST", "/v1/tools/availability", captureResponse: true)
        let late = Task { await store.refreshToolAvailability(original) }
        try await until { await transport.waitingForRequest }
        await store.connect()
        let next = request(store)
        XCTAssertNotEqual(next, original)
        XCTAssertTrue(store.toolAvailability(for: next).isEmpty)
        await transport.setAvailability(response(false))
        await store.refreshToolAvailability(next)
        await transport.releaseRequest(); await late.value
        XCTAssertEqual(store.toolAvailability(for: next)["shell"], false)
        store.connected = false
        XCTAssertTrue(store.toolAvailability(for: next).isEmpty)
    }

    func testUnsupportedEndpointIsQuietAndDoesNotRetryOnCatalogOrModelChanges() async throws {
        for status in [404, 405, 501] {
            let transport = FakeTransport(), store = try makeStore(transport)
            await store.connect()
            await transport.setAvailability(.null, failure: RemoteFailure("Unsupported", statusCode: status))
            await store.refreshToolAvailability(request(store))
            try await store.refresh()
            await store.refreshToolAvailability(request(store))
            await store.refreshToolAvailability(store.toolAvailabilityRequest(model: .object(["id": .string("other")]), settings: .null))
            let bodies = await transport.availabilityBodies
            XCTAssertEqual(bodies.count, 1)
            XCTAssertTrue(store.connected)
            XCTAssertFalse(store.hasPendingCommands)
            XCTAssertNil(store.error)
            XCTAssertTrue(store.toolAvailability(for: request(store)).isEmpty)
            await store.connect()
            await transport.setAvailability(response(true))
            await store.refreshToolAvailability(request(store))
            let retried = await transport.availabilityBodies
            XCTAssertEqual(retried.count, 2, "A new connection may have reached an upgraded host")
            XCTAssertEqual(store.toolAvailability(for: request(store))["shell"], true)
        }
    }

    func testIdenticalLegacyCatalogReadsDoNotRestartSlowAvailabilityTask() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await store.connect()
        let key = request(store)
        await transport.setAvailability(response(true))
        await transport.holdNextRequest("POST", "/v1/tools/availability")
        let read = Task { await store.refreshToolAvailability(key) }
        try await until { await transport.waitingForRequest }
        for _ in 0..<3 {
            await store.poll(reconnect: false)
            XCTAssertEqual(request(store), key, "Unchanged fallback polling must not cancel the visible task")
        }
        await transport.releaseRequest(); await read.value
        XCTAssertEqual(store.toolAvailability(for: key)["shell"], true)
        let bodies = await transport.availabilityBodies
        XCTAssertEqual(bodies.count, 1)
    }

    func testCatalogNotificationInvalidatesVisibleTaskKeyWithoutResettingStatusOrLocalEdits() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.enableChanges()
        let observer = Task { await store.observe() }
        try await until { store.lastChangeNotification != nil }
        let initial = request(store)
        var tools = RemoteSessionCreation.ToolSelection(library: .null)
        tools.setEnabled("shell", true)
        await transport.setAvailability(response(true))
        await store.refreshToolAvailability(initial)
        let taskInvalidations = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = request(store)
        } onChange: {
            taskInvalidations.withLock { $0 += 1 }
        }
        let conversationOnly = RemoteChangeNotification(epoch: "epoch", catalog: "catalog", conversations: ["session": "2"])
        await transport.emit(conversationOnly)
        try await until { store.lastChangeNotification == conversationOnly }
        XCTAssertEqual(request(store), initial, "Transcript-only notices do not restart the selector read")
        XCTAssertEqual(taskInvalidations.withLock { $0 }, 0)
        let catalogChange = RemoteChangeNotification(epoch: "epoch", catalog: "next", conversations: ["session": "2"])
        await transport.emit(catalogChange)
        try await until { store.lastChangeNotification == catalogChange }
        let next = request(store)
        XCTAssertNotEqual(next, initial, "The visible screen's task key follows existing catalog synchronization")
        XCTAssertEqual(taskInvalidations.withLock { $0 }, 1)
        XCTAssertEqual(store.toolAvailability(for: next)["shell"], true)
        await transport.setAvailability(response(false))
        await store.refreshToolAvailability(next)
        XCTAssertEqual(store.toolAvailability(for: next)["shell"], false)
        XCTAssertTrue(tools.isEnabled("shell"), "Availability and shared refreshes must not reinitialize the draft")
        XCTAssertEqual(tools.creationDisabledTools, [])
        observer.cancel(); await observer.value
    }
}
