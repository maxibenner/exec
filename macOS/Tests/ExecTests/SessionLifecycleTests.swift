import AppKit
import SwiftUI

/// Controllable read-only failures and catalog races; never opens a live connection.
actor LifecycleTransport: AgentTransport {
    // Self-contained so the standalone probe need not compile unrelated tests
    // (including the live-helper integration harness).
    actor Responses: AgentTransport {
        struct Request: Sendable {
            let method: String
            let path: String
        }
        private(set) var requests: [Request] = []
        private var replies: [String: Data] = [:]
        private var failures: Set<String> = []
        func reply(_ path: String, _ value: AgentJSON) throws { replies[path] = try JSONEncoder().encode(value) }
        func fail(_ path: String) { failures.insert(path) }
        func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
            requests.append(Request(method: method, path: path))
            let route = String(path.split(separator: "?", maxSplits: 1)[0])
            if failures.contains(route) { throw ExecError("Synthetic read failure") }
            if method == "GET", route.hasSuffix("/sync"), let data = replies[String(route.dropLast(5))] {
                let snapshot = try JSONDecoder().decode(AgentJSON.self, from: data)
                return try JSONEncoder().encode(AgentJSON.object([
                    "snapshot": snapshot, "offset": .number(0), "total": .number(Double(snapshot["messages"].array.count)),
                    "reset": .bool(true), "prefix": snapshot["messages"].array.isEmpty ? .null : .string(String(repeating: "0", count: 64))]))
            }
            guard let data = replies[route] else { throw ExecError("Unexpected lifecycle request: \(method) \(route)") }
            return data
        }
        nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { $0.finish(throwing: ExecError("Unexpected lifecycle event stream")) }
        }
    }
    nonisolated let responses = Responses()
    private var heldCatalogs: [CheckedContinuation<Data, Error>] = []
    private var holdCatalog = false
    private var registration: CheckedContinuation<Data, Error>?
    private var holdRegistration = false
    var registrationPending: Bool { registration != nil }
    func holdRegistrationWrite() { holdRegistration = true }
    func finishRegistration() throws {
        holdRegistration = false
        registration?.resume(returning: try JSONEncoder().encode(AgentLibraryConfiguration()))
        registration = nil
    }
    private(set) var catalogReads = 0
    var pendingCatalogs: Int { heldCatalogs.count }
    func holdCatalogReads(_ hold: Bool) { holdCatalog = hold }
    func finishCatalog(_ value: AgentJSON) throws {
        let reads = heldCatalogs
        heldCatalogs = []
        let data = try JSONEncoder().encode(value)
        for read in reads { read.resume(returning: data) }
    }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        if method == "PATCH", path == "/v1/library", holdRegistration {
            return try await withCheckedThrowingContinuation { registration = $0 }
        }
        if method == "GET", path == "/v1/conversations" {
            catalogReads += 1
            if holdCatalog { return try await withCheckedThrowingContinuation { heldCatalogs.append($0) } }
        }
        return try await responses.request(method, path, body: body)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        responses.events(method, path, body: body)
    }
}

@MainActor final class LifecycleFixture {
    let parentID = UUID()
    let childID = UUID()
    let otherID = UUID()
    let transport = LifecycleTransport()
    let suite = "exec-lifecycle-\(UUID())"
    let preferences: UserDefaults
    let library: ChatLibrary
    let root: AgentJSON
    let child: AgentJSON
    let other: AgentJSON

    init(running: Bool = false, residentLimit: Int = 8) throws {
        preferences = UserDefaults(suiteName: suite)!
        root = .object([
            "id": .string(parentID.uuidString), "model": .string("deepseek/test"), "workspace": .string("/tmp"),
            "configuration": .object(["settings": .object(["systemPrompt": .string(""), "autoApprove": .bool(false)]),
                "instructionsFrozen": .bool(true), "workspaceInstructions": .null]),
            "metadata": .object(["title": .string("Lifecycle parent"), "manuallyNamed": .bool(false), "activityAt": .number(1000)]),
            "messages": .array([.object(["id": .string(UUID().uuidString), "role": .string("user"), "text": .string("Synthetic task")])]),
            "pendingInput": .array([]), "operation": .object(["id": .string(UUID().uuidString), "state": .string("completed")]),
            "approval": .null, "activeToolCallID": .null, "storageError": .null])
        guard case .object(var fields) = root, case .object(var metadata) = fields["metadata"] else {
            throw CheckFailure(description: "Invalid lifecycle fixture")
        }
        fields["id"] = .string(otherID.uuidString)
        metadata["title"] = .string("Other session")
        fields["metadata"] = .object(metadata)
        other = .object(fields)
        fields["id"] = .string(childID.uuidString)
        metadata["title"] = .string("Lifecycle child")
        metadata["parent"] = .object(["sessionId": .string(parentID.uuidString),
            "operationId": root["operation"]["id"], "toolCallId": .string("delegate")])
        fields["metadata"] = .object(metadata)
        if running { fields["operation"] = .object(["id": .string(UUID().uuidString), "state": .string("running")]) }
        child = .object(fields)
        library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences,
                              residentLimit: residentLimit)
    }
    func start() async throws {
        let config = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration()))
        try await transport.responses.reply("/v1/library", config)
        try await transport.responses.reply("/v1/conversations", .array([root, child, other]))
        for snapshot in [root, child, other] {
            try await transport.responses.reply(AgentAPI.path(snapshot.decoded(AgentSnapshot.self).id), snapshot)
        }
        try library.current.apply(root.decoded(AgentSnapshot.self))
        try await library.refreshSharedState()
    }
    func close() {
        library.closePresentations()
        preferences.removePersistentDomain(forName: suite)
    }
    func removeChild(failSync: Bool = true) async throws {
        try await transport.responses.reply("/v1/conversations", .array([root, other]))
        if failSync { await transport.responses.fail(AgentAPI.path(childID, "/sync")) }
    }
}

private struct LifecycleFocusHost: View {
    let library: ChatLibrary
    let windows: SessionWindows
    @FocusState private var focused: Bool
    var body: some View {
        ConversationView(library: library, conversation: library.current,
                         presentation: windows.presentation(for: library.current), focused: $focused,
                         composerFocusRequest: windows.composerFocusRequest)
            .id(ObjectIdentifier(library.current))
    }
}

@MainActor struct SessionLifecycleTests {
    static func wait(_ description: String, until ready: () async -> Bool) async throws {
        for _ in 0..<700 {
            if await ready() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out: \(description)")
    }

    func cleanupOrdersNeverPublishConnectionWarnings() async throws {
        for running in [false, true] {
            for pollFirst in [false, true] {
                for selected in [false, true] {
                    let fixture = try LifecycleFixture(running: running)
                    try await fixture.start()
                    defer { fixture.close() }
                    let library = fixture.library
                    library.openSession(fixture.childID)
                    await library.waitForNavigation()
                    guard library.currentSessionID == fixture.childID else {
                        throw CheckFailure(description: "Child load failed: \(library.error ?? "no error")")
                    }
                    let child = library.current
                    if !selected { library.openSession(fixture.parentID) }
                    try await fixture.removeChild(failSync: pollFirst)
                    if !pollFirst {
                        // Checkpoint-driven catalog refresh, not the two-second
                        // shared-state sweep, must remove the resident overlay.
                        try await library.current.didCheckpoint?()
                    }
                    var warning = false
                    try await Self.wait("confirmed automatic deletion") {
                        warning = warning || child.error != nil
                        return child.deletedRemotely
                    }
                    try expect(!warning && child.error == nil)
                    try expect(!library.sessionList.contains { $0.id == fixture.childID })
                    try expect(library.currentSessionID == fixture.parentID)
                    try expect(!library.needsAttention(fixture.childID))
                }
            }
        }
    }

    func cleanupPreservesDraftsAndRealFailures() async throws {
        let draft = try LifecycleFixture(running: true)
        try await draft.start()
        defer { draft.close() }
        draft.library.openSession(draft.childID)
        await draft.library.waitForNavigation()
        let child = draft.library.current
        child.draft = "Do not discard this input"
        try await draft.removeChild()
        try await Self.wait("deleted draft") { child.deletedRemotely }
        try expect(draft.library.current === child && child.draft == "Do not discard this input")
        try expect(child.error?.contains("Copy your unsent draft") == true)
        try expect(child.summary?.title == "Unsent draft" && !child.busy)
        child.draft = ""
        try await draft.library.refreshSharedState()
        try expect(draft.library.current !== child && !draft.library.openConversations.contains { $0 === child })

        for catalogFails in [false, true] {
            let fixture = try LifecycleFixture(running: true)
            try await fixture.start()
            defer { fixture.close() }
            fixture.library.openSession(fixture.childID)
            await fixture.library.waitForNavigation()
            let resident = fixture.library.current
            if catalogFails { await fixture.transport.responses.fail("/v1/conversations") }
            await fixture.transport.responses.fail(AgentAPI.path(fixture.childID, "/sync"))
            try await Self.wait("real observation failure") { resident.error != nil }
            try expect(resident.error?.contains("Lost connection") == true)
            try expect(!resident.deletedRemotely && resident.busy)
            try expect(fixture.library.sessionList.contains { $0.id == fixture.childID })
        }
        let failure = try LifecycleFixture(running: true)
        try await failure.start()
        defer { failure.close() }
        failure.library.openSession(failure.childID)
        await failure.library.waitForNavigation()
        let failed = failure.library.current
        failed.error = "Real operation failure"
        let reads = await failure.transport.catalogReads
        await failure.transport.responses.fail(AgentAPI.path(failure.childID, "/sync"))
        try await Self.wait("failure catalog confirmation") { await failure.transport.catalogReads > reads }
        try await Task.sleep(for: .milliseconds(20))
        try expect(failed.error == "Real operation failure")
    }

    func cleanupSettlesRemoteCancellationWithoutHidingRealErrors() async throws {
        let fixture = try LifecycleFixture(running: true)
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        library.openSession(fixture.childID)
        await library.waitForNavigation()
        let child = library.current
        guard case .object(var cancelling) = fixture.child else { throw CheckFailure(description: "Invalid child") }
        cancelling["operation"] = .object(["id": fixture.child["operation"]["id"], "state": .string("cancelling")])
        try child.apply(AgentJSON.object(cancelling).decoded(AgentSnapshot.self))
        child.draft = "Unsent during cancellation"
        child.error = "Real operation failure"
        try expect(child.isStopping && child.busy)
        // A local explicit deletion owns its reconciliation until it completes.
        child.beginDeletion()
        try await fixture.removeChild()
        let reportLoss = await child.confirmObservationLoss?()
        try expect(reportLoss == false && !child.deletedRemotely)
        try expect(child.isStopping && child.error == "Real operation failure")
        child.resumeAfterFailedDeletion()
        try await library.refreshSharedState()
        try expect(child.deletedRemotely && !child.busy && !child.isStopping && child.canEditDraft)
        try expect(child.draft == "Unsent during cancellation" && child.error == "Real operation failure")
        try expect(library.current === child)
    }

    func staleCatalogsAndObserverGenerationsCannotRemoveNewResidents() async throws {
        let fixture = try LifecycleFixture(running: true)
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        await fixture.transport.holdCatalogReads(true)
        let old = Task { try await library.current.didCheckpoint?() }
        try await Self.wait("old catalog read") { await fixture.transport.pendingCatalogs == 1 }
        library.openSession(fixture.childID)
        await library.waitForNavigation()
        let child = library.current
        await fixture.transport.holdCatalogReads(false)
        try await fixture.transport.finishCatalog(.array([fixture.root, fixture.other]))
        try await old.value
        try expect(!child.deletedRemotely && library.current === child)

        // A newer catalog supersedes an older absence response.
        await fixture.transport.holdCatalogReads(true)
        let stale = Task { try await library.current.didCheckpoint?() }
        try await Self.wait("stale catalog") { await fixture.transport.pendingCatalogs == 1 }
        await fixture.transport.holdCatalogReads(false)
        try await library.current.didCheckpoint?()
        try await fixture.transport.finishCatalog(.array([fixture.root, fixture.other]))
        try await stale.value
        try expect(!child.deletedRemotely && library.childSessions(of: fixture.parentID).count == 1)

        // Confirmation can suspend while an explicit deletion pauses observation.
        await fixture.transport.holdCatalogReads(true)
        await fixture.transport.responses.fail(AgentAPI.path(fixture.childID, "/sync"))
        try await Self.wait("observer catalog confirmation") { await fixture.transport.pendingCatalogs == 1 }
        child.beginDeletion()
        await fixture.transport.holdCatalogReads(false)
        try await fixture.transport.finishCatalog(.array([fixture.root, fixture.child, fixture.other]))
        try await Task.sleep(for: .milliseconds(30))
        try expect(child.error == nil && !child.deletedRemotely)
    }

    func creationAndRegistrationSurviveOlderAbsence() async throws {
        let fixture = try LifecycleFixture()
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        // A blank resident acquires its backend ID while a catalog read is held.
        library.newConversation()
        let blank = library.current
        await fixture.transport.holdCatalogReads(true)
        let read = Task { try await library.refreshSharedState() }
        try await Self.wait("pre-creation catalog") { await fixture.transport.pendingCatalogs == 1 }
        try blank.apply(fixture.child.decoded(AgentSnapshot.self))
        await fixture.transport.holdCatalogReads(false)
        try await fixture.transport.finishCatalog(.array([fixture.root, fixture.other]))
        try await read.value
        try expect(!blank.deletedRemotely && library.current === blank)

        // The first checkpoint registers its sidebar order. A concurrent catalog
        // read must not delete it while that write is still in flight.
        await fixture.transport.holdRegistrationWrite()
        let checkpoint = Task { try await blank.didCheckpoint?() }
        try await Self.wait("registration write") { await fixture.transport.registrationPending }
        try await fixture.transport.responses.reply("/v1/conversations", .array([fixture.root, fixture.other]))
        try await library.refreshSharedState()
        try expect(!blank.deletedRemotely && library.current === blank)
        try await fixture.transport.responses.reply("/v1/conversations", .array([fixture.root, fixture.child, fixture.other]))
        try await fixture.transport.finishRegistration()
        try await checkpoint.value
        try expect(!blank.deletedRemotely && library.childSessions(of: fixture.parentID).count == 1)
    }

    func cleanupLoadsEvictedParentAndKeepsSafeFallback() async throws {
        for parentAvailable in [false, true] {
            let fixture = try LifecycleFixture(residentLimit: 1)
            try await fixture.start()
            defer { fixture.close() }
            let library = fixture.library
            library.openSession(fixture.childID)
            await library.waitForNavigation()
            try expect(library.openConversations.count == 1)
            if !parentAvailable { await fixture.transport.responses.fail(AgentAPI.path(fixture.parentID, "/sync")) }
            try await fixture.removeChild()
            try await library.current.didCheckpoint?()
            await library.waitForNavigation()
            try expect(library.currentSessionID == (parentAvailable ? fixture.parentID : nil))
            try expect((library.error == nil) == parentAvailable)
            try expect(!library.sessionList.contains { $0.id == fixture.childID })
        }
    }

    func cleanupDuringNavigationRespectsParentWindowOwnership() async throws {
        let fixture = try LifecycleFixture(residentLimit: 1)
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        library.openSession(fixture.childID)
        await library.waitForNavigation()
        try await fixture.transport.responses.reply(AgentAPI.path(fixture.otherID, "/title"), .object([:]))
        try await fixture.removeChild()
        library.renameSession(fixture.otherID, title: "Renamed")
        await library.waitForNavigation()
        try await Self.wait("cold parent after catalog navigation") {
            library.currentSessionID == fixture.parentID && !library.navigating
        }
        try expect(library.error == nil)

        let detached = try LifecycleFixture()
        try await detached.start()
        defer { detached.close() }
        detached.library.detachSession(detached.parentID) { _ in }
        detached.library.openSession(detached.childID)
        await detached.library.waitForNavigation()
        try await detached.removeChild()
        try await detached.library.refreshSharedState()
        try expect(detached.library.currentSessionID == nil && detached.library.error == nil)
        try expect(detached.library.detachedSessionIDs == [detached.parentID])
        try expect(detached.library.openConversations.contains { $0.currentSessionID == detached.parentID })
    }

    func nativeComposerFocusFollowsRequestsAndCleanup() async throws {
        _ = NSApplication.shared
        let fixture = try LifecycleFixture(running: true)
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        let windows = SessionWindows(library: library)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: LifecycleFocusHost(library: library, windows: windows))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        library.current.draft = "parent composer"
        func expectEditor(_ id: UUID, text: String) async throws {
            try await Self.wait("native editor for \(id)") {
                host.layoutSubtreeIfNeeded()
                guard library.currentSessionID == id, let editor = window.firstResponder as? NSTextView else { return false }
                return editor.window === window && editor.isEditable && editor.string == text
            }
        }
        try await expectEditor(fixture.parentID, text: "parent composer")
        windows.openSession(fixture.childID)
        await library.waitForNavigation()
        library.current.draft = "child composer"
        try await expectEditor(fixture.childID, text: "child composer")
        _ = window.makeFirstResponder(host)
        windows.openSession(fixture.childID)
        try await expectEditor(fixture.childID, text: "child composer")
        let editor = window.firstResponder as! NSTextView
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        windows.openSession(fixture.childID)
        windows.openSession(fixture.childID)
        try await Task.sleep(for: .milliseconds(30))
        try expect(window.firstResponder === editor && editor.selectedRange() == NSRange(location: 2, length: 3))
        windows.openSession(fixture.otherID)
        windows.openSession(fixture.parentID)
        windows.openSession(fixture.childID)
        try await expectEditor(fixture.childID, text: "child composer")
        // Reordering disables the current editor without changing the explicit
        // focus request. It must regain native ownership once navigation settles.
        let request = windows.composerFocusRequest
        await fixture.transport.holdRegistrationWrite()
        library.moveSession(fixture.otherID, before: fixture.parentID)
        try await Self.wait("reorder persistence") { await fixture.transport.registrationPending }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        try expect(library.navigating)
        try await fixture.transport.finishRegistration()
        await library.waitForNavigation()
        try expect(windows.composerFocusRequest == request)
        try await expectEditor(fixture.childID, text: "child composer")
        library.current.draft = ""
        try await fixture.removeChild()
        try await library.current.didCheckpoint?()
        try await expectEditor(fixture.parentID, text: "parent composer")
    }
}
