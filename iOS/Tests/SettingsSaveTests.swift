import XCTest
import ExecRemote
@testable import ExecRemoteStore

private actor SettingsTransport: RemoteTransport {
    var isConnected = false
    var patches: [RemoteJSON] = []
    var library: RemoteJSON = .object([
        "automaticTitles": .bool(true),
        "settings": .object(["systemPrompt": .string("Saved prompt"), "autoApprove": .bool(true)])
    ])
    private var holdSave = false
    private var saveWaiter: CheckedContinuation<Void, Never>?
    private var saveFailure: String?
    private var failLibraryReads = false
    private var holdLibrary = false
    private var libraryWaiter: CheckedContinuation<Void, Never>?
    var waitingForLibrary: Bool { libraryWaiter != nil }
    var waitingForSave: Bool { saveWaiter != nil }
    func holdLibraryRead() { holdLibrary = true }
    func releaseLibraryRead() { holdLibrary = false; libraryWaiter?.resume(); libraryWaiter = nil }
    func holdNextSave() { holdSave = true }
    func releaseSave() { saveWaiter?.resume(); saveWaiter = nil }
    func rejectNextSave() { saveFailure = "Host rejected the settings." }
    func rejectLibraryReads(_ value: Bool = true) { failLibraryReads = value }
    func setPrompt(_ prompt: String) {
        merge(.object(["settings": .object(["systemPrompt": .string(prompt)])]))
    }
    func connect(_ host: PairedHost) { isConnected = true }
    func disconnect() { isConnected = false }
    func request(_ method: String, _ path: String, body: RemoteJSON?) async throws -> RemoteJSON {
        guard isConnected else { throw RemoteFailure("Disconnected.") }
        if method == "PATCH", path == "/v1/library", let body {
            patches.append(body)
            let failure = saveFailure
            saveFailure = nil // A duplicate or automatic retry would succeed.
            if holdSave {
                holdSave = false
                await withCheckedContinuation { saveWaiter = $0 }
                try Task.checkCancellation()
            }
            guard isConnected else { throw RemoteFailure("Disconnected.") }
            if let failure { throw RemoteFailure(failure) }
            merge(body)
            return library
        }
        switch (method, path) {
        case ("GET", "/v1/models"), ("GET", "/v1/conversations"): return .array([])
        case ("GET", "/v1/library"):
            if holdLibrary { await withCheckedContinuation { libraryWaiter = $0 } }
            if failLibraryReads { throw RemoteFailure("Could not refresh the library.") }
            return library
        default: throw RemoteFailure("Unexpected fixture request.")
        }
    }
    private func merge(_ patch: RemoteJSON) {
        guard case .object(var fields) = library, case .object(let changes) = patch else { return }
        for (key, value) in changes {
            if key == "settings", case .object(var settings) = fields[key], case .object(let changes) = value {
                settings.merge(changes) { _, new in new }
                fields[key] = .object(settings)
            } else { fields[key] = value }
        }
        library = .object(fields)
    }
}

@MainActor final class SettingsSaveTests: XCTestCase {
    private func makeStore(_ transport: SettingsTransport, connect: Bool = true) async throws -> RemoteStore {
        let invitation = try RemoteJSON.object([
            "version": .number(1), "relay": .string("wss://example.invalid"),
            "route": .string(String(repeating: "a", count: 64)),
            "hostKey": .string(Data(repeating: 0, count: 32).base64EncodedString()),
            "expires": .number(0), "localDevelopment": .bool(false)
        ]).decoded(PairingInvitation.self)
        let host = PairedHost(invitation: invitation, deviceName: "Settings fixture")
        let store = RemoteStore(client: transport, loadHost: { host }, saveHost: { _ in }, forgetHost: {})
        addTeardownBlock { await transport.releaseLibraryRead(); await transport.releaseSave() }
        if connect {
            await store.connect()
            XCTAssertTrue(store.connected)
        }
        store.showSettings()
        return store
    }
    private func waitForSave(_ transport: SettingsTransport) async {
        for _ in 0..<1000 {
            if await transport.waitingForSave { return }
            await Task.yield()
        }
        XCTFail("The settings PATCH did not start.")
    }

    func testSharedSettingsWaitForSuccessfulInitialReadWithoutBlockingDismissal() async throws {
        let transport = SettingsTransport(), store = try await makeStore(transport, connect: false)
        await transport.holdLibraryRead()
        await transport.rejectLibraryReads()
        let connection = Task { await store.connect() }; defer { connection.cancel() }
        for _ in 0..<1000 {
            if await transport.waitingForLibrary { break }
            await Task.yield()
        }
        let waiting = await transport.waitingForLibrary
        XCTAssertTrue(waiting)
        XCTAssertTrue(store.connected, "Authentication can finish before the initial library read")
        XCTAssertFalse(store.hasLoadedLibrary)
        XCTAssertFalse(store.canEditSharedSettings)
        // Neither a direct store call nor a stale UI task may write unloaded defaults.
        await store.mutate("PATCH", "/v1/library", .object(["automaticTitles": .bool(false)]))
        store.settings.prompt = "Uninitialized default must not be saved"
        XCTAssertNil(store.finishSettings())
        XCTAssertFalse(store.settings.isPresented, "Done remains available before shared settings load")
        await transport.releaseLibraryRead()
        await connection.value
        store.showSettings(); store.refreshSettings()
        XCTAssertFalse(store.hasLoadedLibrary, "A failed read must not unlock shared writes")
        XCTAssertFalse(store.canEditSharedSettings)
        await store.mutate("PATCH", "/v1/library", .object(["settings": .object(["autoApprove": .bool(false)])]))
        XCTAssertNil(store.finishSettings())
        let earlyPatches = await transport.patches
        XCTAssertTrue(earlyPatches.isEmpty)

        await transport.rejectLibraryReads(false)
        try await store.refresh()
        store.showSettings(); store.refreshSettings(editing: true)
        XCTAssertTrue(store.canEditSharedSettings)
        XCTAssertEqual(store.settings.prompt, "Saved prompt", "Initialize from the first authoritative library, not defaults")
        XCTAssertEqual(store.settings.actionTitle, "Done")
        store.settings.prompt = "Intentional edit"
        let save = try XCTUnwrap(store.finishSettings())
        await save.value
        let patches = await transport.patches
        XCTAssertEqual(patches, [.object(["settings": .object(["systemPrompt": .string("Intentional edit")])])])
    }

    func testCleanDoneAndRevertedDraftCloseOfflineWithoutPatch() async throws {
        let transport = SettingsTransport(), store = try await makeStore(transport)
        XCTAssertEqual(store.settings.actionTitle, "Done")
        store.settings.prompt = "Unsaved edit"
        XCTAssertEqual(store.settings.actionTitle, "Apply")
        store.settings.prompt = "Saved prompt"
        XCTAssertEqual(store.settings.actionTitle, "Done")
        store.connected = false
        XCTAssertNil(store.finishSettings())
        XCTAssertFalse(store.settings.isPresented)
        let patches = await transport.patches
        XCTAssertTrue(patches.isEmpty)
    }

    func testImmediateSaveControlDoesNotDirtyPromptOrSendAgainOnDone() async throws {
        let transport = SettingsTransport(), store = try await makeStore(transport)
        let patch: RemoteJSON = .object(["automaticTitles": .bool(false)])
        await store.mutate("PATCH", "/v1/library", patch)
        XCTAssertEqual(store.settings.actionTitle, "Done")
        XCTAssertFalse(store.library["automaticTitles"].bool)
        XCTAssertNil(store.finishSettings())
        let patches = await transport.patches
        XCTAssertEqual(patches, [patch])
    }

    func testApplyClosesSynchronouslyAndSaveSurvivesDismissedViewWithoutDuplicatePatch() async throws {
        let transport = SettingsTransport(), store = try await makeStore(transport)
        await transport.holdNextSave()
        store.settings.prompt = "Apply once"
        let save = try XCTUnwrap(store.finishSettings())
        XCTAssertFalse(store.settings.isPresented, "Dismiss before the save task even starts.")
        XCTAssertTrue(store.busy, "Claim the mutation synchronously, not in the task.")
        XCTAssertNil(store.finishSettings(), "A second tap cannot enqueue another PATCH.")
        store.settings.didDismiss()
        let viewWaiter = Task { await save.value }
        viewWaiter.cancel() // View teardown must not cancel the store-owned request.
        await waitForSave(transport)
        store.showSettings() // A recreated sheet sees the same pending draft.
        XCTAssertEqual(store.settings.prompt, "Apply once")
        XCTAssertEqual(store.settings.actionTitle, "Apply")
        XCTAssertNil(store.finishSettings(), "Reopening cannot submit a pending save again.")
        await transport.releaseSave()
        await viewWaiter.value
        XCTAssertFalse(store.busy)
        XCTAssertEqual(store.settings.actionTitle, "Done")
        XCTAssertEqual(store.library["settings"]["systemPrompt"].string, "Apply once")
        XCTAssertNil(store.settings.error)
        let patches = await transport.patches
        XCTAssertEqual(patches, [.object(["settings": .object(["systemPrompt": .string("Apply once")])])])
    }

    func testBackgroundFailureReopensWithDraftAndPersistentUsefulErrorWithoutRetry() async throws {
        let transport = SettingsTransport(), store = try await makeStore(transport)
        await transport.holdNextSave()
        await transport.rejectNextSave()
        store.settings.prompt = "Keep this draft"
        let save = try XCTUnwrap(store.finishSettings())
        store.settings.didDismiss()
        await waitForSave(transport)
        await transport.setPrompt("Another client's prompt")
        try await store.refresh()
        store.settings.refresh(store.library)
        await transport.releaseSave()
        await save.value
        XCTAssertTrue(store.settings.isPresented)
        XCTAssertEqual(store.settings.prompt, "Keep this draft")
        XCTAssertEqual(store.settings.actionTitle, "Apply")
        XCTAssertTrue(store.settings.error?.contains("Host rejected the settings.") == true)
        XCTAssertTrue(store.settings.error?.contains("Your edits are preserved") == true)
        XCTAssertFalse(store.busy)
        // Foreground recovery clears transient errors, but not this save error or draft.
        await store.connect()
        store.showSettings()
        XCTAssertEqual(store.settings.prompt, "Keep this draft")
        XCTAssertNotNil(store.settings.error)
        let patches = await transport.patches
        XCTAssertEqual(patches.count, 1)
    }

    func testFastFailureReopensOnlyAfterDismissalFinishes() async throws {
        let transport = SettingsTransport(), store = try await makeStore(transport)
        await transport.rejectNextSave()
        store.settings.prompt = "Fast failure draft"
        let save = try XCTUnwrap(store.finishSettings())
        await save.value // Reject while the sheet is still animating out.
        XCTAssertFalse(store.settings.isPresented)
        XCTAssertNotNil(store.settings.error)
        store.settings.didDismiss()
        store.settings.refresh(store.library) // The new sheet's onAppear.
        XCTAssertTrue(store.settings.isPresented)
        XCTAssertEqual(store.settings.prompt, "Fast failure draft")
        XCTAssertEqual(store.settings.actionTitle, "Apply")
        let patches = await transport.patches
        XCTAssertEqual(patches.count, 1)
    }

    func testAcceptedSaveStaysClosedAndCleanWhenFollowUpReadFails() async throws {
        let transport = SettingsTransport(), store = try await makeStore(transport)
        await transport.rejectLibraryReads()
        store.settings.prompt = "Accepted prompt"
        let save = try XCTUnwrap(store.finishSettings())
        store.settings.didDismiss()
        await save.value
        XCTAssertFalse(store.settings.isPresented)
        XCTAssertEqual(store.settings.actionTitle, "Done")
        XCTAssertNil(store.settings.error)
        XCTAssertEqual(store.error, "Could not refresh the library.")
        store.showSettings()
        XCTAssertEqual(store.settings.prompt, "Accepted prompt", "Use the PATCH receipt even without a successful GET.")
        XCTAssertNil(store.finishSettings())
        let patches = await transport.patches
        XCTAssertEqual(patches.count, 1)
    }

    func testSuspensionDuringSaveReopensDraftWithoutReplayingOnReconnect() async throws {
        let transport = SettingsTransport(), store = try await makeStore(transport)
        await transport.holdNextSave()
        store.settings.prompt = "Interrupted draft"
        let save = try XCTUnwrap(store.finishSettings())
        store.settings.didDismiss()
        await waitForSave(transport)
        await store.suspend()
        await transport.releaseSave()
        await save.value
        XCTAssertTrue(store.settings.isPresented)
        XCTAssertEqual(store.settings.prompt, "Interrupted draft")
        XCTAssertTrue(store.settings.error?.contains("Disconnected.") == true)
        await store.connect()
        store.settings.refresh(store.library)
        XCTAssertEqual(store.settings.prompt, "Interrupted draft")
        XCTAssertEqual(store.settings.actionTitle, "Apply")
        XCTAssertNotNil(store.settings.error)
        let patches = await transport.patches
        XCTAssertEqual(patches.count, 1)
    }
}
