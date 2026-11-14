import Foundation

private actor ImageQueueTransport: AgentTransport {
    let requests = FakeAgentTransport()
    private(set) var uploading = false
    private var release: CheckedContinuation<Void, Never>?
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        if path.hasSuffix("/images") {
            uploading = true
            await withCheckedContinuation { release = $0 }
        }
        return try await requests.request(method, path, body: body)
    }
    func finishUpload() { release?.resume(); release = nil }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { _ in }
    }
}

@MainActor struct ImageQueueTests {
    func queuesImagesWithoutReplayingOrChangingOperation() async throws {
        for finishesDuringUpload in [false, true] {
            let transport = ImageQueueTransport()
            let requests = transport.requests
            let id = AgentIntegrationTests.conversationID
            let imageID = UUID()
            let image = ImageAttachment(id: imageID, name: "queued.png", mediaType: "image/png", data: Data([1]))
            try await requests.reply("/v1/providers", .array([.object([
                "id": .string("deepseek"), "name": .string("Test"), "connected": .bool(true)])]))
            try await requests.reply(AgentAPI.path(id, "/images"), .object([
                "id": .string(imageID.uuidString), "name": .string(image.name), "mediaType": .string(image.mediaType),
                "width": .number(1), "height": .number(1), "byteCount": .number(1), "sha256": .string(String(repeating: "0", count: 64))]))
            let running = try AgentIntegrationTests.fixture(state: "running")
            try await requests.reply(AgentAPI.path(id), running)
            let provider = AgentAccounts(api: AgentAPI(transport: transport))
            try await provider.refreshConnections()
            let store = ChatStore(provider: provider)
            defer { store.closePresentation() }
            store.installModels([ChatModel(id: "deepseek/test", name: "Test")])
            try store.apply(running.decoded(AgentSnapshot.self))
            store.draftImages = [image] // Image-only input is valid steering.
            store.send()
            for _ in 0..<200 {
                if await transport.uploading { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let uploading = await transport.uploading
            try expect(uploading)
            if finishesDuringUpload {
                let completed = try AgentIntegrationTests.fixture(state: "completed", result: true)
                try store.apply(completed.decoded(AgentSnapshot.self))
                try await requests.reply(AgentAPI.path(id), completed)
                await requests.fail(AgentAPI.path(id, "/steer"))
            }
            await transport.finishUpload()
            await store.waitUntilIdle()
            let writes = await requests.requests.filter { $0.method == "POST" }
            try expect(writes.map(\.path) == [AgentAPI.path(id, "/images"), AgentAPI.path(id, "/steer")])
            let body = try JSONDecoder().decode(AgentJSON.self, from: writes.last!.body!)
            try expect(body["operationID"].string == AgentIntegrationTests.operationID.uuidString.lowercased())
            try expect(body["text"].string == "" && body["images"].array.count == 1)
            try expect(store.draftImages == (finishesDuringUpload ? [image] : []))
            try expect((store.error != nil) == finishesDuringUpload)
        }
    }
}
