import Foundation
import SwiftUI

private actor SessionReadTransport: AgentTransport {
    nonisolated let responses = FakeAgentTransport()
    var holdReads = false
    private var pending: (id: UUID, path: String, result: CheckedContinuation<Data, Error>)?
    var hasPendingRead: Bool { pending != nil }
    func setHolding(_ value: Bool) { holdReads = value }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        guard holdReads, path.contains("/sync") else { return try await responses.request(method, path, body: body) }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending = (id, path, $0) }
        } onCancel: { Task { await self.cancelRead(id) } }
    }
    private func cancelRead(_ id: UUID) {
        guard pending?.id == id else { return }
        pending?.result.resume(throwing: CancellationError()); pending = nil
    }
    func finishRead(_ snapshot: AgentJSON) throws {
        guard let pending else { throw CheckFailure(description: "No pending sync read") }
        let page = try AgentSyncFixture.page(snapshot, path: pending.path)
        self.pending = nil
        pending.result.resume(returning: try JSONEncoder().encode(page))
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        responses.events(method, path, body: body)
    }
}

private actor SessionCreationTransport: AgentTransport {
    nonisolated let responses = FakeAgentTransport()
    private var pending: CheckedContinuation<Data, Error>?
    var creationRequested: Bool { pending != nil }

    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        if method == "POST", path == "/v1/conversations" {
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return try await responses.request(method, path, body: body)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        responses.events(method, path, body: body)
    }
    func finishCreation(_ snapshot: AgentJSON) async throws {
        let id = try snapshot.decoded(AgentSnapshot.self).id
        try await responses.reply(AgentAPI.path(id), snapshot)
        let data = try JSONEncoder().encode(snapshot)
        pending?.resume(returning: data); pending = nil
    }
    func failCreation() {
        pending?.resume(throwing: ExecError("Creation could not be confirmed.")); pending = nil
    }
}

@MainActor struct SessionPresentationTests {
    private func newSnapshot() throws -> AgentJSON {
        let encoded = String(decoding: try JSONEncoder().encode(AgentIntegrationTests.fixture(state: "completed", result: true)), as: UTF8.self)
        let oldID = AgentIntegrationTests.conversationID, newID = UUID(uuidString: "ffffffff-1111-4111-8111-111111111111")!
        let data = Data(encoded.replacingOccurrences(of: oldID.uuidString.lowercased(), with: newID.uuidString.lowercased())
            .replacingOccurrences(of: oldID.uuidString, with: newID.uuidString).utf8)
        return try JSONDecoder().decode(AgentJSON.self, from: data)
    }
    private func makeLibrary(_ transport: SessionCreationTransport, preferences: UserDefaults) async throws -> ChatLibrary {
        preferences.set(try JSONEncoder().encode([ChatModel(id: "deepseek/test", name: "Test")]), forKey: "chat.modelCatalog")
        let config = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(AgentLibraryConfiguration()))
        try await transport.responses.reply("/v1/library", config)
        let initial = try AgentIntegrationTests.fixture(state: "completed", result: true)
        try await transport.responses.reply("/v1/conversations", .array([initial]))
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        try library.current.apply(initial.decoded(AgentSnapshot.self))
        try await library.refreshSharedState()
        return library
    }
    private func waitForCreation(_ transport: SessionCreationTransport) async throws {
        for _ in 0..<200 {
            if await transport.creationRequested { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out awaiting session creation")
    }

    func newSessionStartsAtTop() async throws {
        let suite = "exec-sidebar-order-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = SessionCreationTransport()
        let library = try await makeLibrary(transport, preferences: preferences)
        defer { library.closePresentations(); Task { await transport.failCreation() } }
        let first = library.current
        let host = NSHostingView(rootView: SessionSidebar(store: library, open: { library.openSession($0) }, delete: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await expectSidebar(host, rows: 1, selectedRow: -1)
        library.newConversation()
        let creating = library.current
        try expect(creating !== first && creating.currentSessionID == nil)
        try expect(library.sidebarSessions.map(\.id) == [first.currentSessionID!])
        try expect(library.sidebarSelectionID == first.currentSessionID)
        try await waitForCreation(transport)
        // Keep selection stable for the entire request, not just the initial frame.
        try expect(library.sidebarSelectionID == first.currentSessionID)
        let next = try newSnapshot()
        let nextID = try next.decoded(AgentSnapshot.self).id
        try await transport.finishCreation(next)
        await creating.waitForPendingSave()
        try expect(creating.error == nil)
        try expect(library.sidebarSessions.map(\.id) == [nextID, first.currentSessionID!])
        try expect(library.sidebarSelectionID == nextID)
        // The active session changes, but AppKit must have no selected row to
        // paint with an accent color when the sidebar becomes first responder.
        try await expectSidebar(host, rows: 2, selectedRow: -1)
    }

    // Exercise the actual native List, not just the catalog backing it.
    // This verifies reconciliation and absence of native selection, not animation appearance.
    private func expectSidebar(_ host: NSView, rows: Int, selectedRow: Int) async throws {
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if let table = table(in: host), table.numberOfRows == rows,
               table.selectedRow == selectedRow { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CheckFailure(description: "Sidebar did not reconcile native rows and selection")
    }

    func creationSelectionClearsOnFailureAndDoesNotStealNavigation() async throws {
        for navigateAway in [false, true] {
            let suite = "exec-sidebar-handoff-\(UUID())"
            let preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            let transport = SessionCreationTransport()
            let library = try await makeLibrary(transport, preferences: preferences)
            defer { library.closePresentations(); Task { await transport.failCreation() } }
            let first = library.current
            library.newConversation()
            let creating = library.current
            try await waitForCreation(transport)
            try expect(library.sidebarSelectionID == first.currentSessionID)
            if navigateAway {
                library.openSession(first.currentSessionID!)
                try await transport.finishCreation(newSnapshot())
            } else {
                await transport.failCreation()
            }
            await creating.waitForPendingSave()
            if navigateAway {
                try expect(library.current === first && library.sidebarSelectionID == first.currentSessionID)
            } else {
                try expect(creating.hasUnsavedChanges && library.sidebarSelectionID == nil)
                try expect(library.sidebarSessions.map(\.id) == [first.currentSessionID!])
            }
        }
    }

    func deletionIgnoresStreamClosureAndResumesOnFailure() async throws {
        let transport = SessionReadTransport()
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        let active = try AgentIntegrationTests.fixture(state: "running")
        try await transport.responses.reply(AgentAPI.path(AgentIntegrationTests.conversationID), active)
        try await store.loadSession(AgentIntegrationTests.conversationID)
        await transport.setHolding(true)
        for _ in 0..<200 {
            if await transport.hasPendingRead { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let readPending = await transport.hasPendingRead
        try expect(readPending)
        store.beginDeletion()
        for _ in 0..<100 {
            if await !transport.hasPendingRead { break }
            await Task.yield()
        }
        let readCancelled = await !transport.hasPendingRead
        try expect(readCancelled)
        try expect(store.error == nil && !store.hasUnsavedChanges)
        store.resumeAfterFailedDeletion()
        for _ in 0..<200 {
            if await transport.hasPendingRead { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let resumed = await transport.hasPendingRead
        try expect(resumed)
        try await transport.finishRead(AgentIntegrationTests.fixture(state: "completed", result: true))
        for _ in 0..<100 where store.busy { try await Task.sleep(for: .milliseconds(5)) }
        try expect(!store.busy && store.error == nil)
    }
}
