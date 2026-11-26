import Foundation

private actor LiveAutoModeTransport: AgentTransport {
    enum Outcome { case acknowledged, rejected, acknowledgementLost }

    private let sessionPath: String
    private var snapshot: AgentJSON
    private var nextOutcome: Outcome
    private var heldPath: String?
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var requests: [FakeAgentTransport.Request] = []
    var waiting: Bool { pending != nil }

    init(path: String, snapshot: AgentJSON, firstWrite: Outcome = .acknowledged) {
        sessionPath = path; self.snapshot = snapshot; nextOutcome = firstWrite
    }
    func hold(_ path: String) { heldPath = path }
    func release(thenHold path: String? = nil) {
        heldPath = path
        pending?.resume(); pending = nil
    }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        requests.append(.init(method: method, path: path, body: body))
        if heldPath == path {
            heldPath = nil
            await withCheckedContinuation { pending = $0 }
        }
        let route = String(path.split(separator: "?", maxSplits: 1)[0])
        if method == "GET", route == sessionPath + "/sync" {
            return try JSONEncoder().encode(AgentSyncFixture.page(snapshot, path: path))
        }
        guard method == "PUT", path == sessionPath + "/auto-approve", let body,
              case .bool(let enabled) = try JSONDecoder().decode(AgentJSON.self, from: body)["autoApprove"] else {
            throw CheckFailure(description: "Unexpected live Auto request: \(method) \(path)")
        }
        let outcome = nextOutcome
        nextOutcome = .acknowledged
        if outcome != .rejected {
            guard case .object(var fields) = snapshot,
                  case .object(var configuration) = fields["configuration"],
                  case .object(var settings) = configuration["settings"] else {
                throw CheckFailure(description: "Invalid live Auto snapshot fixture")
            }
            settings["autoApprove"] = .bool(enabled)
            configuration["settings"] = .object(settings)
            fields["configuration"] = .object(configuration)
            snapshot = .object(fields)
        }
        switch outcome {
        case .acknowledged: return try JSONEncoder().encode(AgentJSON.object(["autoApprove": .bool(enabled)]))
        case .rejected: throw AgentHTTPError(status: 409, message: "Synthetic Auto write rejected")
        case .acknowledgementLost: throw ExecError("Synthetic Auto write acknowledgement lost")
        }
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            guard method == "GET", path == "/v1/changes" else {
                continuation.finish(throwing: CheckFailure(description: "Unexpected live Auto event stream: \(path)"))
                return
            }
            // No invalidations after startup: a held or failed PUT must not depend on polling to reconcile.
            continuation.yield(Data(#"{"epoch":"live-auto-test","catalog":"1","conversations":{}}"#.utf8))
        }
    }
}

@MainActor struct LiveAutoModeTests {
    private let id = AgentIntegrationTests.conversationID
    private var path: String { AgentAPI.path(id) }
    private var modePath: String { path + "/auto-approve" }
    private var syncPath: String { path + "/sync" }

    private func expectWrites(_ modes: [Bool], in requests: [FakeAgentTransport.Request]) throws {
        let writes = requests.filter { $0.method != "GET" }
        try expect(writes.count == modes.count)
        for (request, mode) in zip(writes, modes) {
            try expect(request.method == "PUT" && request.path == modePath)
            guard let body = request.body else { throw CheckFailure(description: "Missing Auto write body") }
            try expect(try JSONDecoder().decode(AgentJSON.self, from: body) == .object(["autoApprove": .bool(mode)]))
        }
    }

    func activeModeChangesWaitForSnapshotBeforeUpdatingComposerLabel() async throws {
        let transport = LiveAutoModeTransport(path: path, snapshot: try AgentIntegrationTests.fixture(state: "running", result: true))
        let suite = "exec-live-auto-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        defer {
            library.closePresentations()
            preferences.removePersistentDomain(forName: suite)
            Task { await transport.release() }
        }
        let store = library.current
        try await store.loadSession(id)
        let panel = ChatPanel(library: library, conversation: store)
        // The composer renders this value; do not require a visible window or AX state.
        try expect(!panel.autoApproveTools)
        for enabled in [true, false] {
            try expect(panel.isWorking && store.canSetAutoApproveTools)
            let before = await transport.requests.count
            await transport.hold(modePath)
            panel.setAutoApproveTools(enabled)
            try await SessionLifecycleTests.wait("held Auto PUT") { await transport.waiting }
            try expect(panel.autoApproveTools == !enabled && !store.canSetAutoApproveTools)
            let heldRequests = await transport.requests.dropFirst(before).filter { $0.method != "GET" }
            try expect(heldRequests.map(\.path) == [modePath])

            await transport.release(thenHold: syncPath)
            try await SessionLifecycleTests.wait("held Auto reconciliation read after acknowledgement") { await transport.waiting }
            // The mode-only receipt is not an authoritative conversation snapshot.
            try expect(panel.autoApproveTools == !enabled && !store.canSetAutoApproveTools)
            await transport.release()
            await store.waitForPendingSave()
            try expect(panel.autoApproveTools == enabled && panel.isWorking && store.canSetAutoApproveTools && store.error == nil)
        }
        try expectWrites([true, false], in: await transport.requests)
    }

    func modeChangePreservesPendingApproval() async throws {
        let transport = LiveAutoModeTransport(path: path, snapshot: try AgentIntegrationTests.fixture())
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer {
            store.closePresentation()
            Task { await transport.release() }
        }
        try await store.loadSession(id)
        let approval = store.tools.pendingApproval, messages = store.messages
        try expect(approval?.id == AgentIntegrationTests.approvalID && messages.last?.pendingTool?.isAwaitingApproval == true)

        await transport.hold(modePath)
        store.setAutoApproveTools(true)
        try await SessionLifecycleTests.wait("held Auto PUT with approval pending") { await transport.waiting }
        try expect(store.tools.pendingApproval?.id == approval?.id && store.messages == messages)
        await transport.release()
        await store.waitForPendingSave()
        try expect(store.autoApproveTools && store.busy && store.error == nil)
        try expect(store.tools.pendingApproval?.id == approval?.id && store.tools.pendingApproval?.content == approval?.content)
        try expect(store.messages == messages)
        try expectWrites([true], in: await transport.requests)
    }

    func failedModeWritesReconcileWithoutRetry() async throws {
        // An idle existing session still uses the mode endpoint, not a full settings save.
        for committed in [false, true] {
            let transport = LiveAutoModeTransport(path: path,
                snapshot: try AgentIntegrationTests.fixture(state: "completed", result: true),
                firstWrite: committed ? .acknowledgementLost : .rejected)
            let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
            defer { store.closePresentation() }
            try await store.loadSession(id)
            store.setAutoApproveTools(true)
            await store.waitForPendingSave()
            try expect(store.error?.contains(committed ? "acknowledgement lost" : "write rejected") == true)
            try expect(store.autoApproveTools == committed && !store.busy && !store.hasUnsavedChanges && store.canSetAutoApproveTools)
            let requests = await transport.requests
            try expectWrites([true], in: requests)
            let afterWrite = requests.drop(while: { $0.method == "GET" }).dropFirst()
            try expect(afterWrite.contains { $0.method == "GET" && $0.path == syncPath })
        }
    }
}
