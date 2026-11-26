import Foundation
import CryptoKit

private actor FileQueueTransport: AgentTransport {
    let requests = FakeAgentTransport()
    private(set) var uploading = false
    private var release: CheckedContinuation<Void, Never>?
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        if path.hasSuffix("/files") {
            uploading = true
            await withCheckedContinuation { release = $0 }
        }
        return try await requests.request(method, path, body: body)
    }
    func finishUpload() { release?.resume(); release = nil }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        requests.events(method, path, body: body)
    }
}

@MainActor struct FileAttachmentTests {
    func copiesFilesAndKeepsMixedImportsAtomic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("report.pdf")
        let bytes = Data("%PDF-1.7\nopaque data\0".utf8)
        try bytes.write(to: url)
        let batch = try AttachmentDrop.loadFile(url)
        try FileManager.default.removeItem(at: url)
        try expect(batch.images.isEmpty && batch.files.count == 1)
        try expect(batch.files[0].data == bytes && batch.files[0].name == "report.pdf")
        try expectFailure { _ = try AttachmentDrop.loadFile(root) }
        let large = root.appendingPathComponent("large.txt")
        try Data(repeating: 0, count: FileAttachment.maximumBytes + 1).write(to: large)
        try expectFailure { _ = try AttachmentDrop.loadFile(large) }
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: large)
        try expectFailure { _ = try AttachmentDrop.loadFile(link) }
        let store = ChatStore(provider: AgentAccounts(api: AgentAPI(transport: FakeAgentTransport())))
        defer { store.closePresentation() }
        let image = ImageAttachment(name: "image.png", mediaType: "image/png", data: Data([1]))
        await store.importAttachments { AttachmentDrop.Batch(images: [image], files: batch.files) }?.value
        try expect(store.draftImages == [image] && store.draftFiles == batch.files && store.hasUnsentDraft)
        await store.importAttachments { AttachmentDrop.Batch(files: Array(repeating: batch.files[0], count: 3)) }?.value
        try expect(store.error != nil && store.draftImages == [image] && store.draftFiles == batch.files)
        store.draftImages = []; store.draftFiles = []
        try expect(!store.hasUnsentDraft)
    }

    func queuesFilesWithoutReplayingOrChangingOperation() async throws {
        for finishesDuringUpload in [false, true] {
            let transport = FileQueueTransport()
            let requests = transport.requests
            let id = AgentIntegrationTests.conversationID
            let assetID = UUID()
            let file = FileAttachment(name: "queued.csv", data: Data("a,b\n1,2".utf8))
            let digest = SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined()
            let ref: AgentJSON = .object([
                "id": .string(assetID.uuidString), "name": .string(file.name), "path": .string("/private/session-files/queued.csv"),
                "byteCount": .number(Double(file.data.count)), "sha256": .string(digest)])
            try await requests.reply("/v1/providers", .array([.object([
                "id": .string("deepseek"), "name": .string("Test"), "connected": .bool(true)])]))
            try await requests.reply(AgentAPI.path(id, "/files"), ref)
            let running = try AgentIntegrationTests.fixture(state: "running")
            try await requests.reply(AgentAPI.path(id), running)
            let provider = AgentAccounts(api: AgentAPI(transport: transport))
            try await provider.refreshConnections()
            let store = ChatStore(provider: provider)
            defer { store.closePresentation() }
            store.installModels([ChatModel(id: "deepseek/test", name: "Test")])
            try store.apply(running.decoded(AgentSnapshot.self))
            store.draftFiles = [file]
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
            try expect(writes.map(\.path) == [AgentAPI.path(id, "/files"), AgentAPI.path(id, "/steer")])
            let body = try JSONDecoder().decode(AgentJSON.self, from: writes.last!.body!)
            try expect(body["operationID"].string == AgentIntegrationTests.operationID.uuidString.lowercased())
            try expect(body["text"].string == "" && body["files"].array.first?.string == assetID.uuidString.lowercased())
            try expect(store.draftFiles == (finishesDuringUpload ? [file] : []))
            try expect((store.error != nil) == finishesDuringUpload)
            // Queued file cards restore without downloading the original.
            guard case .object(var object) = running else { throw CheckFailure(description: "Invalid fixture") }
            object["pendingInput"] = .array([.object(["id": .string(UUID().uuidString), "role": .string("user"), "text": .string(""), "files": .array([ref])])])
            let snapshot = try AgentJSON.object(object).decoded(AgentSnapshot.self)
            let queued = snapshot.queuedMessages(images: [:])
            try expect(queued.first?.files.first?.id == assetID)
            try expect(queued.first?.files.first?.data.isEmpty == true)
        }
    }
}
