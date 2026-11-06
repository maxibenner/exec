import AppKit

@MainActor struct ImageGenerationTests {
    private let call = ToolCall(id: "image-1", name: "generate_image", arguments: #"{"prompt":"A small red square","transparent_background":false}"#)

    private func provider(_ http: URLSession) throws -> OpenAIProvider {
        let credentials = MemoryCredentials()
        credentials.data = try JSONEncoder().encode(OpenAIAuthentication.Session(
            subject: "test-user", email: "test@example.com", accountID: "workspace",
            access: "test-access", refresh: "test-refresh", expires: Date().addingTimeInterval(3600)))
        return try OpenAIProvider(authentication: OpenAIAuthentication(keychain: credentials, http: http), http: http)
    }

    private func terminal(_ output: [[String: Any]]) throws -> Data {
        Data("data: ".utf8) + (try JSONSerialization.data(withJSONObject: ["type": "response.completed", "response": ["status": "completed", "output": output]])) + Data("\n\n".utf8)
    }

    private func toolReply() throws -> HTTPStub.Reply {
        .init(chunks: [try terminal([["type": "function_call", "call_id": call.id, "name": call.name, "arguments": call.arguments]])])
    }

    private func png() throws -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
        return bitmap.representation(using: .png, properties: [:])!
    }

    private func configure(_ store: ChatStore) {
        store.models = [ChatModel(id: "test", name: "Test", contextWindow: 100_000)]
        store.selectedModel = "test"
        store.draft = "Generate an image"
    }

    func roundTrip() async throws {
        let bytes = try png()
        let response = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": bytes.base64EncodedString()]]])
        let http = HTTPStub.makeSession([try toolReply(), .init(chunks: [response]),
            .init(chunks: [try terminal([["type": "message", "content": [["type": "output_text", "text": "Done"]]]])])])
        defer { http.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let store = ChatStore(provider: try provider(http), sessions: sessions, newConversation: true)
        configure(store)
        store.send()
        await store.waitUntilIdle()
        try expect(store.error == nil && HTTPStub.state.requests.count == 3)
        let request = HTTPStub.state.requests[1]
        try expect(request.url?.absoluteString == CodexConnection.baseURL + "/images/generations")
        try expect(request.httpMethod == "POST")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access")
        try expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "workspace")
        let body = try JSONSerialization.jsonObject(with: HTTPStub.body(of: request)) as! [String: String]
        try expect(body == ["model": "gpt-image-2", "prompt": "A small red square", "background": "opaque", "quality": "auto", "size": "auto"])
        let saved = try await sessions.load(id: store.currentSessionID)!
        let result = saved.history.compactMap(\.toolResult).first!
        try expect(result.generatedImage?.data == bytes && result.screenshot == nil)
        let imageFile = try await sessions.saveImage(result.generatedImage!)
        try expect(imageFile.pathExtension == "png" && result.text.contains(imageFile.path))
        try expect(try Data(contentsOf: imageFile) == bytes)
        let json = try String(contentsOf: root.appendingPathComponent("\(store.currentSessionID!).json"), encoding: .utf8)
        try expect(!json.contains(bytes.base64EncodedString()) && json.contains(imageFile.lastPathComponent))
        try expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("images").path).count == 1)
        let followup = String(decoding: HTTPStub.body(of: HTTPStub.state.requests[2]), as: UTF8.self)
        try expect(followup.contains("input_image") && followup.contains("Generated image from tool call"))
        let display = ToolPresentation(result)
        try expect(display.title == "Generate image" && display.icon == "photo" && display.summary == "A small red square")
        let legacy = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(ToolResult(call: call, text: "old")))
        try expect(legacy.generatedImage == nil)
    }

    func failuresAndValidation() async throws {
        for reply in [HTTPStub.Reply(status: 403), .init(status: 429), .init(chunks: [Data(#"{"data":[]}"#.utf8)]),
                      .init(chunks: [Data(#"{"data":[{"b64_json":"bm90IGFuIGltYWdl"}]}"#.utf8)])] {
            let http = HTTPStub.makeSession([try toolReply(), reply])
            let store = ChatStore(provider: try provider(http), newConversation: true)
            configure(store)
            store.send()
            await store.waitUntilIdle()
            try expect(store.error != nil && HTTPStub.state.requests.count == 2)
            try expect(store.messages.last?.toolResult?.generatedImage == nil)
            try expect(store.messages.last?.text == ImageGenerationTool.interrupted)
            http.invalidateAndCancel()
        }
        try expectFailure { _ = try ImageGenerationTool.Request(prompt: "  ", transparent_background: false).validated() }
        try expectFailure { _ = try ImageGenerationTool.Request(prompt: String(repeating: "x", count: 16_385), transparent_background: false).validated() }
        try expectFailure { _ = try CodexImages.image(Data(repeating: 0, count: CodexImages.maximumResponseBytes + 1)) }
        let http = HTTPStub.makeSession([.init(chunks: [Data(repeating: 0, count: 20)])])
        defer { http.invalidateAndCancel() }
        do {
            _ = try await OpenAITransport.boundedResponse(URLRequest(url: URL(string: "https://example.com")!), session: http, maximumBytes: 10)
            throw CheckFailure(description: "Expected response bound failure")
        } catch is ExecError {}
        try expect(HTTPStub.state.requests.count == 1)
    }

    func cancellationAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let http = HTTPStub.makeSession([try toolReply(), .init(holdOpen: true)])
        defer { http.invalidateAndCancel() }
        let store = ChatStore(provider: try provider(http), sessions: sessions, newConversation: true)
        configure(store)
        store.send()
        for _ in 0..<400 {
            if HTTPStub.state.heldCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try expect(HTTPStub.state.heldCount == 1)
        var checkpoint = try await sessions.load(id: store.currentSessionID)!
        try expect(checkpoint.activeCallID == call.id && checkpoint.recoverInterruptedTurn())
        try expect(checkpoint.history.last?.text == ImageGenerationTool.interrupted)
        store.stop()
        await store.waitUntilIdle()
        try expect(HTTPStub.state.requests.count == 2 && store.error == nil)
        try expect(store.messages.last?.text == ImageGenerationTool.interrupted)
        let restarted = ChatStore(provider: try provider(http), sessions: sessions, newConversation: true)
        restarted.openSession(store.currentSessionID!, loadModels: false)
        await restarted.waitUntilIdle()
        try expect(restarted.messages.last?.text == ImageGenerationTool.interrupted)
        try expect(HTTPStub.state.requests.count == 2)
    }
}
