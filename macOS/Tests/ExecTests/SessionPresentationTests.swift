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

private actor SessionReorderTransport: AgentTransport {
    nonisolated let responses = FakeAgentTransport()
    private var pending: CheckedContinuation<Data, Error>?
    private(set) var writes = 0
    var isWaiting: Bool { pending != nil }

    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        if method == "PATCH", path == "/v1/library" {
            writes += 1
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        return try await responses.request(method, path, body: body)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        responses.events(method, path, body: body)
    }
    func finish(_ configuration: AgentLibraryConfiguration?) throws {
        guard let pending else { throw CheckFailure(description: "No pending reorder") }
        self.pending = nil
        if let configuration {
            pending.resume(returning: try JSONEncoder().encode(configuration))
        } else {
            pending.resume(throwing: ExecError("Reorder could not be confirmed."))
        }
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

    func reorderPublishesBeforePersistenceAndReconciles() async throws {
        for succeeds in [true, false] {
            let suite = "exec-sidebar-drop-\(UUID())"
            let preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            let transport = SessionReorderTransport()
            let first = try AgentIntegrationTests.fixture(state: "completed", result: true)
            let second = try newSnapshot()
            let ids = try [first, second].map { try $0.decoded(AgentSnapshot.self).id }
            var configuration = AgentLibraryConfiguration()
            configuration.order = ids
            let configJSON = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(configuration))
            try await transport.responses.reply("/v1/library", configJSON)
            try await transport.responses.reply("/v1/conversations", .array([first, second]))
            let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
            defer { library.closePresentations() }
            try await library.refreshSharedState()
            try expect(library.sidebarSessions.map(\.id) == ids)

            library.moveSidebarSessions(from: IndexSet(integer: 0), to: 2)
            let dropped = Array(ids.reversed())
            // No yield: the native drop needs this order in the same transaction.
            try expect(library.sidebarSessions.map(\.id) == dropped)
            try expect(library.isReorderingSessions && !library.canReorderSessions)
            for _ in 0..<200 {
                if await transport.isWaiting { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let waiting = await transport.isWaiting
            try expect(waiting)
            // Polling is gated during navigation; checkpoint refreshes can still
            // arrive and must not undo the pending drop.
            try await library.refreshSharedState()
            try await library.current.didCheckpoint?()
            try expect(library.sidebarSessions.map(\.id) == dropped)
            library.moveSidebarSessions(from: IndexSet(integer: 0), to: 2)
            try expect(library.sidebarSessions.map(\.id) == dropped)
            configuration.order = dropped
            try await transport.finish(succeeds ? configuration : nil)
            for _ in 0..<200 {
                if !library.navigating { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try expect(!library.navigating && !library.isReorderingSessions)
            try expect(library.sidebarSessions.map(\.id) == (succeeds ? dropped : ids))
            try expect((library.error == nil) == succeeds)
            let writes = await transport.writes
            try expect(writes == 1)
        }
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
        let creating = library.pendingNewConversation!
        try expect(library.current === first && creating !== first && creating.currentSessionID == nil)
        try expect(creating.workspace == nil && creating.needsInitialWorkspaceSelection)
        try expect(library.sidebarSessions.map(\.id) == [first.currentSessionID!])
        try expect(library.sidebarSelectionID == first.currentSessionID)
        try creating.setInitialWorkspace(Workspace(root: first.workspace!.root))
        creating.scheduleSave()
        try await waitForCreation(transport)
        // Keep both the transcript and selection stable for the entire request.
        try expect(library.current === first && library.hasConversation(first))
        try expect(library.sidebarSelectionID == first.currentSessionID)
        let next = try newSnapshot()
        let nextID = try next.decoded(AgentSnapshot.self).id
        try await transport.finishCreation(next)
        await creating.waitForPendingSave()
        try expect(creating.error == nil && library.current === creating && library.pendingNewConversation == nil)
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

    func creationKeepsCurrentOnFailureAndDoesNotStealNavigation() async throws {
        for navigateAway in [false, true] {
            let suite = "exec-sidebar-handoff-\(UUID())"
            let preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            let transport = SessionCreationTransport()
            let library = try await makeLibrary(transport, preferences: preferences)
            defer { library.closePresentations(); Task { await transport.failCreation() } }
            let first = library.current
            library.newConversation()
            let creating = library.pendingNewConversation!
            try creating.setInitialWorkspace(Workspace(root: first.workspace!.root))
            creating.scheduleSave()
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
                try expect(creating.hasUnsavedChanges && library.error != nil)
                try expect(library.current === first && library.sidebarSelectionID == first.currentSessionID)
                try expect(library.sidebarSessions.map(\.id) == [first.currentSessionID!])
            }
        }
    }

    func subagentsResizeTheirNativeParentRowWithoutReplacingIt() async throws {
        let suite = "exec-sidebar-children-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let transport = FakeAgentTransport()
        let parent = try AgentIntegrationTests.fixture(state: "completed", result: true)
        let neighbor = try newSnapshot()
        let parentID = AgentIntegrationTests.conversationID
        var configuration = AgentLibraryConfiguration()
        configuration.order = [parentID, try neighbor.decoded(AgentSnapshot.self).id]
        try await transport.reply("/v1/library", try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(configuration)))
        try await transport.reply("/v1/conversations", .array([parent, neighbor]))
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        defer { library.closePresentations() }
        try library.current.apply(parent.decoded(AgentSnapshot.self))
        try await library.refreshSharedState()
        let host = NSHostingView(rootView: SessionSidebar(store: library, open: { library.openSession($0) }, delete: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await expectSidebar(host, rows: 2, selectedRow: -1)
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { findTable($0) }.first
        }
        guard let table = findTable(host) else { throw CheckFailure(description: "Missing sidebar table") }
        let initialHeight = table.rect(ofRow: 0).height
        let initialNeighborY = table.rect(ofRow: 1).minY
        guard let parentRow = table.rowView(atRow: 0, makeIfNecessary: true) else {
            throw CheckFailure(description: "Missing native parent row")
        }
        func menus(in view: NSView) -> [SessionContextMenu.MenuView] {
            (view as? SessionContextMenu.MenuView).map { [$0] } ?? view.subviews.flatMap { menus(in: $0) }
        }
        func isParentMenu(_ menu: SessionContextMenu.MenuView) -> Bool {
            menu.items.contains { item in
                if case .action("Rename…", _, _) = item { return true }
                return false
            }
        }
        func frame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: host) }
        guard let initialParentMenu = menus(in: parentRow).first(where: isParentMenu) else {
            throw CheckFailure(description: "Missing native parent menu")
        }
        let initialParentHitFrame = frame(initialParentMenu)
        func topInParentRow(_ view: NSView) -> CGFloat {
            let rect = view.convert(view.bounds, to: parentRow)
            return parentRow.isFlipped ? rect.minY : parentRow.bounds.maxY - rect.maxY
        }
        let initialParentTop = topInParentRow(initialParentMenu)
        let children = try (0..<2).map { index -> AgentJSON in
            guard case .object(var fields) = try AgentIntegrationTests.fixture(state: "running"),
                  case .object(var metadata) = fields["metadata"] else { throw CheckFailure(description: "Invalid fixture") }
            fields["id"] = .string(UUID().uuidString)
            metadata["title"] = .string("Sub-agent \(index + 1)")
            metadata["parent"] = .object([
                "sessionId": .string(parentID.uuidString),
                "operationId": .string(AgentIntegrationTests.operationID.uuidString),
                "toolCallId": .string("delegate")])
            fields["metadata"] = .object(metadata)
            return .object(fields)
        }
        var childHeight: CGFloat?
        for count in [2, 1, 0] {
            try await transport.reply("/v1/conversations", .array([parent, neighbor] + Array(children.prefix(count))))
            try await library.refreshSharedState()
            var resized = false
            var previousHeight: CGFloat?
            var stableSamples = 0
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                let height = table.rect(ofRow: 0).height
                let delta = height - initialHeight
                stableSamples = previousHeight.map { abs($0 - height) < 0.1 } == true ? stableSamples + 1 : 0
                previousHeight = height
                let expectedSize = count == 0 ? abs(delta) < 1 : delta >= CGFloat(count * 15) && delta < CGFloat(count * 30)
                // Do not mistake an intermediate animated height for the final layout.
                if expectedSize && stableSamples >= 3 {
                    resized = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            try expect(resized)
            try expect(table.numberOfRows == 2 && table.selectedRow == -1)
            try expect(table.rowView(atRow: 0, makeIfNecessary: true) === parentRow)
            let heightDelta = table.rect(ofRow: 0).height - initialHeight
            if count == 2 { childHeight = heightDelta / 2 }
            try expect(abs(heightDelta - CGFloat(count) * (childHeight ?? 0)) < 1)
            try expect(abs(table.rect(ofRow: 1).minY - initialNeighborY - heightDelta) < 1)
            try expect(library.sidebarSelectionID == parentID)
            let rowMenus = menus(in: parentRow)
            try expect(rowMenus.count == count + 1)
            guard let parentMenu = rowMenus.first(where: isParentMenu) else {
                throw CheckFailure(description: "Missing parent hit area")
            }
            let parentHitFrame = frame(parentMenu)
            try expect(abs(parentHitFrame.minX - initialParentHitFrame.minX) < 0.1)
            // Compare row-local top edges, not screen Y (List can scroll to keep
            // its contents in view as the native family's height changes).
            guard abs(topInParentRow(parentMenu) - initialParentTop) < 0.5 else {
                throw CheckFailure(description: "Parent top inset changed from \(initialParentTop) to \(topInParentRow(parentMenu)) with \(count) children")
            }
            try expect(abs(parentHitFrame.width - initialParentHitFrame.width) < 0.1)
            // Native subview order is not SwiftUI row order; identify menus by
            // their actions rather than mistaking the last child for its parent.
            for childMenu in rowMenus where !isParentMenu(childMenu) {
                let hitFrame = frame(childMenu)
                // Padding belongs inside the child's full-width native menu/click
                // area, not on the family or outside the selection background.
                try expect(abs(hitFrame.minX - parentHitFrame.minX) < 0.1)
                try expect(abs(hitFrame.width - parentHitFrame.width) < 0.1)
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
