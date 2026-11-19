import Foundation

private actor ApprovalDecisionTransport: AgentTransport {
    nonisolated let responses = FakeAgentTransport()
    private var release: CheckedContinuation<Void, Never>?
    private var holdDecision = true
    var waiting: Bool { release != nil }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        if method == "POST", path.hasSuffix("/approvals"), holdDecision {
            holdDecision = false
            await withCheckedContinuation { release = $0 }
        }
        return try await responses.request(method, path, body: body)
    }
    func finish() { release?.resume(); release = nil }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        responses.events(method, path, body: body)
    }
}

@MainActor struct ToolApprovalRecoveryTests {
    func failedDecisionsReconcileAuthoritativelyWithoutResending() async throws {
        let id = AgentIntegrationTests.conversationID
        let path = AgentAPI.path(id)
        let approvalID = AgentIntegrationTests.approvalID
        for outcome in ["pending", "restore", "consumed", "readFailure", "replacement"] {
            let transport = ApprovalDecisionTransport()
            let initial = try AgentIntegrationTests.fixture()
            let completed = try AgentIntegrationTests.fixture(state: "completed", result: true)
            try await transport.responses.reply(path, initial)
            await transport.responses.failNext(path + "/approvals")
            let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
            defer { store.closePresentation() }
            // Warm the incremental reader. The failure must not depend on a future
            // state change to restore an approval whose authoritative value is unchanged.
            try await store.loadSession(id)
            store.tools.resolveApproval(id: approvalID, approved: true)
            try await SessionLifecycleTests.wait("held approval decision") { await transport.waiting }
            store.tools.resolveApproval(id: approvalID, approved: false)
            let before = await transport.responses.requests.filter { $0.path.contains("/sync") }.count
            var expectedID: UUID? = approvalID
            if outcome == "restore" { try store.apply(completed.decoded(AgentSnapshot.self)) }
            if outcome == "consumed" {
                try await transport.responses.reply(path, completed)
                expectedID = nil
            }
            if outcome == "readFailure" { await transport.responses.fail(path + "/sync") }
            if outcome == "replacement" {
                guard case .object(var fields) = initial, case .object(var approval) = fields["approval"] else {
                    throw CheckFailure(description: "Invalid approval fixture")
                }
                expectedID = UUID()
                approval["id"] = .string(expectedID!.uuidString)
                fields["approval"] = .object(approval)
                try await transport.responses.reply(path, .object(fields))
            }
            await transport.finish()
            try await SessionLifecycleTests.wait("failed decision reconciliation") { store.error?.contains("Not retried") == true }
            try expect(store.tools.pendingApproval?.id == expectedID)
            let requests = await transport.responses.requests
            let reads = requests.filter { $0.path.contains("/sync") }
            let decisions = requests.filter { $0.path == path + "/approvals" }
            try expect(reads.count > before && decisions.count == 1)
            try expect(reads.filter { $0.path == path + "/sync" }.count >= 2)
            let decision = try JSONDecoder().decode(AgentJSON.self, from: decisions[0].body!)
            try expect(decision["operationID"].string == AgentIntegrationTests.operationID.uuidString.lowercased())
            try expect(decision["approvalID"].string == approvalID.uuidString.lowercased() && decision["approved"].bool)
            if outcome == "pending" {
                try store.apply(initial.decoded(AgentSnapshot.self))
                try expect(store.tools.pendingApproval?.id == approvalID)
                for _ in 0..<10 { await Task.yield() }
                let unchanged = await transport.responses.requests.filter { $0.path == path + "/approvals" }
                try expect(unchanged.count == 1)
                // Only another explicit user decision is allowed to submit again.
                store.tools.resolveApproval(id: approvalID, approved: false)
                try await SessionLifecycleTests.wait("explicit approval correction") { store.tools.pendingApproval == nil }
                let explicit = await transport.responses.requests.filter { $0.path == path + "/approvals" }
                try expect(explicit.count == 2)
                let corrected = try JSONDecoder().decode(AgentJSON.self, from: explicit[1].body!)
                try expect(!corrected["approved"].bool)
            }
        }
    }
}
