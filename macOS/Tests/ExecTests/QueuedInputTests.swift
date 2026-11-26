import CryptoKit
import Foundation

private actor HeldQueuedInputTransport: AgentTransport {
    let replies = FakeAgentTransport()
    private var heldPath: String?
    private var pending: CheckedContinuation<Void, Never>?
    var waiting: Bool { pending != nil }

    func hold(_ path: String) { heldPath = path }
    func release(thenHold path: String? = nil) {
        heldPath = path
        pending?.resume(); pending = nil
    }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        if path == heldPath {
            heldPath = nil
            await withCheckedContinuation { pending = $0 }
        }
        return try await replies.request(method, path, body: body)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        replies.events(method, path, body: body)
    }
}

@MainActor struct QueuedInputTests {
    private let firstID = UUID(uuidString: "abcdefab-4444-4444-8444-444444444444")!
    private let secondID = UUID()
    private var path: String { AgentAPI.path(AgentIntegrationTests.conversationID) }
    private var cancelPath: String { path + "/cancel-input" }

    private func input(_ id: UUID) -> AgentJSON {
        .object(["id": .string(id.uuidString), "role": .string("user"), "text": .string("Queued input")])
    }
    private func snapshot(_ state: String = "running", queue: [AgentJSON], promoted: [AgentJSON] = []) throws -> AgentJSON {
        let fixture = try AgentIntegrationTests.fixture(state: state, result: true)
        guard case .object(var fields) = fixture else { throw CheckFailure(description: "Invalid queued input fixture") }
        fields["messages"] = .array(fixture["messages"].array + promoted)
        fields["pendingInput"] = .array(queue)
        return .object(fields)
    }
    private func expectSingleCancellation(in requests: [FakeAgentTransport.Request]) throws {
        let writes = requests.filter { $0.method != "GET" }
        try expect(writes.count == 1 && writes.first?.method == "POST" && writes.first?.path == cancelPath)
        guard let body = writes.first?.body else { throw CheckFailure(description: "Missing cancellation body") }
        try expect(try JSONDecoder().decode(AgentJSON.self, from: body) == .object([
            "operationID": .string(AgentIntegrationTests.operationID.uuidString.lowercased()),
            "messageID": .string(firstID.uuidString.lowercased())]))
        try expect(requests.drop(while: { $0.method != "POST" }).dropFirst().contains { $0.method == "GET" && $0.path == path + "/sync" })
    }

    func projectsQueuedAttachmentsAndPromotesByStableID() async throws {
        let transport = FakeAgentTransport()
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer { store.closePresentation() }
        let image = ImageAttachment(id: UUID(), name: "queued.png", mediaType: "image/png", data: Data([1]))
        let file = FileAttachment(id: UUID(), name: "queued.txt", path: "/tmp/queued.txt")
        let digest = SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined()
        let attachment: AgentJSON = .object([
            "id": .string(firstID.uuidString), "role": .string("user"), "text": .string("Read these"),
            "images": .array([.object(["id": .string(image.id.uuidString), "name": .string(image.name),
                "mediaType": .string(image.mediaType), "width": .number(1), "height": .number(1),
                "byteCount": .number(1), "sha256": .string(digest)])]),
            "files": .array([.object(["id": .string(file.id.uuidString), "name": .string(file.name),
                "path": .string("/tmp/queued.txt"), "byteCount": .number(1), "sha256": .string(digest)])])])
        try await transport.reply("/v1/images/\(image.id.uuidString.lowercased())", .object(["base64": .string(image.data.base64EncodedString())]))
        let queue = [attachment, input(secondID)]
        try store.apply(snapshot("interrupted", queue: queue).decoded(AgentSnapshot.self))
        try expect(store.hasUnsentDraft && !store.busy && store.canCancelQueuedInput)
        try expect(store.queuedMessages.map(\.id) == [firstID, secondID])
        try expect(!store.messages.contains { $0.id == firstID || $0.id == secondID })
        try await SessionLifecycleTests.wait("queued image hydration") { store.queuedMessages.first?.images == [image] }
        let projected = Message(id: firstID, role: .user, text: "Read these", images: [image], files: [file])
        try expect(store.queuedMessages.first == projected)

        // If the same ID is present in both fields, the authoritative transcript wins.
        try store.apply(snapshot(queue: queue, promoted: [attachment]).decoded(AgentSnapshot.self))
        try expect(store.queuedMessages.map(\.id) == [secondID])
        try expect(store.messages.filter { $0.id == firstID } == [projected])
    }

    func cancellationWaitsForSnapshotAndIsDisabledDuringStopAndSync() async throws {
        let transport = HeldQueuedInputTransport()
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        defer {
            store.closePresentation()
            Task { await transport.release() }
        }
        let queue = [input(firstID), input(secondID)]
        try store.apply(snapshot("cancelling", queue: queue).decoded(AgentSnapshot.self))
        try expect(store.isStopping && !store.canCancelQueuedInput)
        store.cancelQueuedInput(firstID)
        try expect(!store.isSaving)

        try store.apply(snapshot("interrupted", queue: queue).decoded(AgentSnapshot.self))
        try await transport.replies.reply(path, snapshot("interrupted", queue: [input(secondID)]))
        try await transport.replies.reply(cancelPath, .object(["messageID": .string(firstID.uuidString.lowercased())]))
        store.cancelQueuedInput(UUID()) // Not in the queue.
        try expect(store.canCancelQueuedInput && !store.isSaving)
        await transport.hold(cancelPath)
        store.cancelQueuedInput(firstID)
        store.cancelQueuedInput(secondID)
        try await SessionLifecycleTests.wait("held queued input cancellation") { await transport.waiting }
        try expect(store.isSaving && !store.canCancelQueuedInput && store.queuedMessages.map(\.id) == [firstID, secondID])

        await transport.release(thenHold: path + "/sync")
        try await SessionLifecycleTests.wait("held cancellation reconciliation") { await transport.waiting }
        try expect(store.isSaving && !store.canCancelQueuedInput && store.queuedMessages.map(\.id) == [firstID, secondID])
        store.cancelQueuedInput(secondID)
        await transport.release()
        await store.waitForPendingSave()
        try expect(!store.isSaving && store.canCancelQueuedInput && store.error == nil)
        try expect(store.queuedMessages.map(\.id) == [secondID] && !store.messages.contains { $0.id == firstID })
        try expectSingleCancellation(in: await transport.replies.requests)
    }

    func cancellationFailuresReconcileWithoutReplayOrDuplicatingPromotedInput() async throws {
        for (retained, promoted) in [(true, false), (false, false), (false, true)] {
            let transport = FakeAgentTransport()
            let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: transport)))
            defer { store.closePresentation() }
            let queued = input(firstID)
            try store.apply(snapshot(queue: [queued]).decoded(AgentSnapshot.self))
            try await transport.reply(path, snapshot(queue: retained ? [queued] : [], promoted: promoted ? [queued] : []))
            await transport.fail(cancelPath)
            store.cancelQueuedInput(firstID)
            await store.waitForPendingSave()
            try expect(store.error?.contains("Not retried") == true && store.busy)
            try expect(store.queuedMessages.map(\.id) == (retained ? [firstID] : []))
            try expect(store.hasUnsentDraft == retained && store.canCancelQueuedInput == retained)
            try expect(store.messages.filter { $0.id == firstID }.count == (promoted ? 1 : 0))
            try expectSingleCancellation(in: await transport.requests)
        }
    }
}
