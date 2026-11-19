import Foundation
import CryptoKit

/// Holds preparation or an already-dispatched inference request without cancelling it.
private actor SubmissionSafetyTransport: AgentTransport {
    nonisolated let responses = FakeAgentTransport()
    let heldSuffix: String
    private var release: CheckedContinuation<Void, Never>?
    private var holdRequest = true
    var waiting: Bool { release != nil }
    init(holding suffix: String) { heldSuffix = suffix }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        if method == "POST", path.hasSuffix(heldSuffix), holdRequest {
            holdRequest = false
            await withCheckedContinuation { release = $0 }
        }
        return try await responses.request(method, path, body: body)
    }
    func finish() { release?.resume(); release = nil }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        responses.events(method, path, body: body)
    }
}

@MainActor struct SubmissionSafetyTests {
    private var id: UUID { AgentIntegrationTests.conversationID }
    private var path: String { AgentAPI.path(id) }

    private func store(_ transport: SubmissionSafetyTransport, running: Bool) async throws -> ChatStore {
        try await transport.responses.reply("/v1/providers", .array([.object([
            "id": .string("deepseek"), "name": .string("Test"), "connected": .bool(true)])]))
        let snapshot = try AgentIntegrationTests.fixture(state: running ? "running" : "completed", result: true)
        try await transport.responses.reply(path, snapshot)
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        try await provider.refreshConnections()
        let store = ChatStore(provider: provider)
        store.installModels([ChatModel(id: "deepseek/test", name: "Test")])
        try store.apply(snapshot.decoded(AgentSnapshot.self))
        return store
    }

    func stopAndCloseDuringUploadsNeverDispatchAndPreserveDrafts() async throws {
        for asset in ["images", "files"] {
            for running in [false, true] {
                for close in [false, true] {
                    let transport = SubmissionSafetyTransport(holding: "/" + asset)
                    let store = try await store(transport, running: running)
                    defer { store.closePresentation() }
                    let image = ImageAttachment(name: "held.png", mediaType: "image/png", data: Data([1]))
                    let file = FileAttachment(name: "held.csv", data: Data("a,b".utf8))
                    let assetID = UUID()
                    let ref: AgentJSON = asset == "images" ? .object([
                        "id": .string(assetID.uuidString), "name": .string(image.name), "mediaType": .string(image.mediaType),
                        "width": .number(1), "height": .number(1), "byteCount": .number(1),
                        "sha256": .string(String(repeating: "0", count: 64))]) : .object([
                        "id": .string(assetID.uuidString), "name": .string(file.name), "path": .string("/tmp/held.csv"),
                        "byteCount": .number(Double(file.data.count)),
                        "sha256": .string(SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined())])
                    try await transport.responses.reply(path + "/" + asset, ref)
                    store.draft = "Keep this draft"
                    store.draftImages = asset == "images" ? [image, ImageAttachment(name: image.name, mediaType: image.mediaType, data: image.data)] : []
                    store.draftFiles = asset == "files" ? [file, FileAttachment(name: file.name, data: file.data)] : []
                    let images = store.draftImages, files = store.draftFiles
                    store.send()
                    try await SessionLifecycleTests.wait("held \(asset) upload") { await transport.waiting }
                    if close { store.closePresentation() }
                    else { store.stop(); store.stop() }
                    await transport.finish()
                    await store.waitUntilIdle()
                    if !close {
                        if running {
                            try await SessionLifecycleTests.wait("existing operation cancellation") {
                                await transport.responses.requests.contains { $0.path == path + "/cancel" }
                            }
                            try await transport.responses.reply(path, AgentIntegrationTests.fixture(state: "interrupted", result: true))
                        }
                        try await SessionLifecycleTests.wait("pre-dispatch Stop settlement") { !store.isStopping }
                    }
                    try expect(store.draft == "Keep this draft" && store.draftImages == images && store.draftFiles == files)
                    try expect(store.error == nil)
                    let writes = await transport.responses.requests.filter { $0.method != "GET" }
                    // Stop/close must also prevent the second upload, not just inference.
                    try expect(writes.filter { $0.path == path + "/" + asset }.count == 1)
                    try expect(!writes.contains { $0.path.hasSuffix("/turns") || $0.path.hasSuffix("/steer") })
                    let cancels = writes.filter { $0.path == path + "/cancel" }
                    try expect(cancels.count == (!close && running ? 1 : 0))
                    if let cancel = cancels.first {
                        let body = try JSONDecoder().decode(AgentJSON.self, from: cancel.body!)
                        try expect(body["operationID"].string == AgentIntegrationTests.operationID.uuidString.lowercased())
                    }
                    if close {
                        store.send()
                        await store.waitUntilIdle()
                        let afterClose = await transport.responses.requests.filter { $0.method != "GET" }
                        try expect(afterClose.count == writes.count)
                    }
                }
            }
        }
    }

    func stopAfterDispatchReconcilesOnceAndCancelsOnlyConfirmedOperation() async throws {
        for receipt in ["confirmed", "lost", "replaced"] {
            let transport = SubmissionSafetyTransport(holding: "/turns")
            let store = try await store(transport, running: false)
            defer { store.closePresentation() }
            try await transport.responses.reply(path + "/turns", .object([
                "operationID": .string(AgentIntegrationTests.operationID.uuidString)]))
            store.draft = "Single request"
            store.send()
            try await SessionLifecycleTests.wait("dispatched turn") { await transport.waiting }
            store.stop(); store.stop()
            let beforeReceipt = await transport.responses.requests
            try expect(!beforeReceipt.contains { $0.path == path + "/cancel" })
            guard case .object(var active) = try AgentIntegrationTests.fixture(state: "running", result: true) else {
                throw CheckFailure(description: "Invalid running fixture")
            }
            if receipt == "lost" { await transport.responses.fail(path + "/turns") }
            if receipt == "replaced" {
                active["operation"] = .object(["id": .string(UUID().uuidString), "state": .string("running")])
            }
            try await transport.responses.reply(path, .object(active))
            await transport.finish()
            await store.waitUntilIdle()
            if receipt == "confirmed" {
                try await SessionLifecycleTests.wait("accepted turn cancellation") {
                    await transport.responses.requests.contains { $0.path == path + "/cancel" }
                }
                try await transport.responses.reply(path, AgentIntegrationTests.fixture(state: "interrupted", result: true))
            }
            try await SessionLifecycleTests.wait("dispatched Stop settlement") { !store.isStopping }
            let requests = await transport.responses.requests
            let turns = requests.filter { $0.path == path + "/turns" }
            let cancels = requests.filter { $0.path == path + "/cancel" }
            try expect(turns.count == 1 && cancels.count == (receipt == "confirmed" ? 1 : 0))
            try expect(requests.contains { $0.path.contains("/sync") })
            try expect(store.draft == (receipt == "lost" ? "Single request" : ""))
            try expect((store.error == nil) == (receipt == "confirmed"))
            if let cancel = cancels.first {
                let body = try JSONDecoder().decode(AgentJSON.self, from: cancel.body!)
                try expect(body["operationID"].string == AgentIntegrationTests.operationID.uuidString.lowercased())
            }
        }
    }
}
