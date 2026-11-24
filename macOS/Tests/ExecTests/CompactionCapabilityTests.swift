import Foundation

@MainActor struct CompactionCapabilityTests {
    private var path: String { AgentAPI.path(AgentIntegrationTests.conversationID) }

    private func snapshot(_ state: String = "completed", model: String = "deepseek/test",
                          support: Bool? = true, pending: Bool = false, history: Bool = true) throws -> AgentJSON {
        guard case .object(var fields) = try AgentIntegrationTests.fixture(state: state, result: true) else {
            throw CheckFailure(description: "Expected snapshot fixture")
        }
        fields["model"] = .string(model)
        fields["supportsCompaction"] = support.map { .bool($0) }
        fields["pendingInput"] = .array(pending ? [.object([
            "id": .string(UUID().uuidString), "role": .string("user"), "text": .string("Queued input")
        ])] : [])
        if !history { fields["messages"] = .array([]) }
        return .object(fields)
    }

    private func wait(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out awaiting compaction capability state")
    }

    func reportedCapabilityIsConservativeAndModelSpecific() async throws {
        for model in ["deepseek/test", "mock/test", "openai/test"] {
            for support in [nil, false, true] as [Bool?] {
                let transport = FakeAgentTransport()
                let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
                defer { store.closePresentation() }
                let value = try snapshot(model: model, support: support).decoded(AgentSnapshot.self)
                try expect(value.supportsCompaction == support)
                try store.apply(value)
                try expect(store.canCompact == (support == true))
                if support != true { store.compact() }
                // Even another model from the same provider needs its own authoritative capability.
                store.selectedModel = model + "-next"
                try expect(!store.canCompact)
                store.compact()
                store.selectedModel = model
                try expect(store.canCompact == (support == true))
                for _ in 0..<5 { await Task.yield() }
                let requests = await transport.requests
                try expect(requests.isEmpty)
            }
        }
    }

    func busyRequestsRemainQueueableButPendingAndEmptyHistoryAreUnavailable() async throws {
        let transport = FakeAgentTransport()
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        try expect(!store.canCompact)
        try store.apply(snapshot("running").decoded(AgentSnapshot.self))
        try expect(store.busy && store.canCompact)
        for state in ["running", "completed"] {
            try store.apply(snapshot(state, pending: true).decoded(AgentSnapshot.self))
            try expect(!store.canCompact)
            store.compact()
        }
        try store.apply(snapshot(history: false).decoded(AgentSnapshot.self))
        try expect(store.messages.isEmpty && !store.canCompact)
        store.compact()
        for _ in 0..<5 { await Task.yield() }
        let requests = await transport.requests
        try expect(requests.isEmpty)
    }

    func queuedCompactionRechecksCapabilityAfterModelSelection() async throws {
        for support in [nil, false, true] as [Bool?] {
            let transport = FakeAgentTransport()
            let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
            defer { store.closePresentation() }
            try store.apply(snapshot("running", model: "openai/test").decoded(AgentSnapshot.self))
            store.compact(); store.compact()
            store.selectedModel = "deepseek/test"
            store.scheduleSave()
            try expect(!store.canCompact)
            let selected = try snapshot(support: support)
            try await transport.reply(path + "/model", selected)
            try await transport.reply(path, selected)
            try await transport.reply(path + "/compact", .object([
                "operationID": .string(AgentIntegrationTests.operationID.uuidString)
            ]))
            let before = await transport.requests
            try expect(before.isEmpty)
            try store.apply(snapshot(model: "openai/test").decoded(AgentSnapshot.self))
            try await wait { !store.busy }
            let writes = await transport.requests.filter { $0.method != "GET" }
            try expect(writes.map(\.path) == (support == true ? [path + "/model", path + "/compact"] : [path + "/model"]))
            try expect(store.selectedModel == "deepseek/test" && store.canCompact == (support == true))
            try expect((store.error != nil) == (support != true))
        }
    }
}
