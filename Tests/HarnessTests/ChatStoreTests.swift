import Foundation

@MainActor private final class FakeProvider: ChatProvider {
    let connectionTitle = "Connect to Test"
    var account: String? = "test@example.com"
    var inputs: [[Message]] = []
    var shouldFail = false
    var holdOpen = false
    var pending: AsyncThrowingStream<ChatEvent, Error>.Continuation?

    func connect() async throws { account = "test@example.com" }
    func disconnect() async throws { account = nil }
    func models() async throws -> [ChatModel] { [ChatModel(id: "test", name: "Test")] }
    func send(_ messages: [Message], model: String) -> AsyncThrowingStream<ChatEvent, Error> {
        inputs.append(messages)
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("Hello"))
            continuation.yield(.text(" world"))
            if holdOpen { pending = continuation }
            else if shouldFail { continuation.finish(throwing: HarnessError("failed")) }
            else { continuation.yield(.completed); continuation.finish() }
        }
    }
}

@MainActor struct ChatStoreTests {
    private func settle(_ store: ChatStore) async throws {
        for _ in 0..<200 {
            if !store.busy { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw HarnessError("Operation did not settle")
    }

    func successfulFollowupIncludesHistoryAndNewClearsIt() async throws {
        let provider = FakeProvider()
        let store = ChatStore(provider: provider)
        store.restore()
        try await settle(store)
        store.draft = "First"
        store.send()
        // A duplicate click cannot start another turn.
        store.send()
        try await settle(store)
        try expect(provider.inputs.count == 1)
        try expect(store.messages.last?.text == "Hello world")
        store.draft = "Second"
        store.send()
        try await settle(store)
        try expect(provider.inputs.last?.map(\.text) == ["First", "Hello world", "Second"])
        store.newConversation()
        store.draft = "Fresh"
        store.send()
        try await settle(store)
        try expect(provider.inputs.last?.map(\.text) == ["Fresh"])
    }

    func failedTurnsStayVisibleButAreExcludedFromContext() async throws {
        let provider = FakeProvider()
        let store = ChatStore(provider: provider)
        store.selectedModel = "test"
        store.draft = "First"
        store.send()
        try await settle(store)
        provider.shouldFail = true
        store.draft = "Failed"
        store.send()
        try await settle(store)
        try expect(store.error == "failed")
        try expect(store.messages.last?.text == "Hello world")
        try expect(store.messages.last?.status == .failed)
        provider.shouldFail = false
        store.draft = "Retry"
        store.send()
        try await settle(store)
        try expect(provider.inputs.last?.map(\.text) == ["First", "Hello world", "Retry"])
    }

    func stopCancelsAndDoesNotCommitPartialTurn() async throws {
        let provider = FakeProvider()
        provider.holdOpen = true
        let store = ChatStore(provider: provider)
        store.selectedModel = "test"
        store.draft = "Interrupt"
        store.send()
        for _ in 0..<200 {
            if provider.pending != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(provider.pending != nil)
        store.stop()
        try await settle(store)
        try expect(!store.busy)
        try expect(store.error?.contains("Stopped") == true)
        try expect(store.messages.last?.status == .interrupted)
        provider.holdOpen = false
        provider.pending?.finish()
        store.draft = "Next"
        store.send()
        try await settle(store)
        try expect(provider.inputs.last?.map(\.text) == ["Next"])
    }
}
