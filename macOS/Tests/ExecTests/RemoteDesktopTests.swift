import Foundation

@MainActor struct RemoteDesktopTests {
    private func wait(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Timed out awaiting remote desktop state")
    }

    private func binding(frontend: String, conversation: AgentJSON) -> AgentJSON {
        .object(["type": .string("conversation_bound"), "frontendID": .string(frontend),
                 "conversationID": conversation])
    }

    private func request(frontend: String, conversation: UUID) -> AgentJSON {
        .object([
            "id": .string("remote-capture"), "frontendID": .string(frontend),
            "conversationID": .string(conversation.uuidString.lowercased()),
            "operationID": .string(AgentIntegrationTests.operationID.uuidString.lowercased()),
            "callID": .string("remote-call"),
            "action": .object(["target": .string("list_windows"), "windowID": .null])])
    }

    func remoteBindingEnablesCaptureOnUseAndClearsOnDisconnect() async throws {
        let transport = ControlledAgentTransport()
        let frontend = "11111111-2222-4333-8444-555555555555"
        let conversation = AgentIntegrationTests.conversationID
        let captureConversation = UUID()
        var permission = false, permissionRequests = 0, captureCount = 0
        let desktop = AgentDesktop(api: AgentAPI(transport: transport), preflight: { permission }, requestPermission: {
            permissionRequests += 1; permission = true; return true
        }, capture: { _ in
            captureCount += 1
            return .init(text: "Test windows", windows: [.init(id: 42, title: "Test window")])
        })
        defer { desktop.stop() }
        try transport.emit(.object(["type": .string("registered"), "frontendID": .string(frontend)]))
        try await desktop.start()
        try expect(desktop.frontendID == frontend && desktop.enabled.isEmpty)

        try transport.emit(binding(frontend: frontend, conversation: .string(conversation.uuidString)))
        try await wait { desktop.enabled == [conversation] }
        try expect(permissionRequests == 0 && captureCount == 0 && !permission)
        let bindingRequests = await transport.requests.requests
        try expect(bindingRequests.isEmpty) // Binding needs neither OS consent nor a PUT /desktop handshake.

        // A fresh binding and request must work back-to-back on the same ordered channel.
        let captureRequest = request(frontend: frontend, conversation: captureConversation)
        try transport.emit(binding(frontend: frontend, conversation: .string(captureConversation.uuidString)))
        try transport.emit(.object(["type": .string("request"), "request": captureRequest]))
        try await wait {
            await transport.requests.requests.contains { $0.path == "/v1/native/results" }
        }
        try expect(desktop.enabled == [conversation, captureConversation])
        try expect(permissionRequests == 1 && captureCount == 1 && permission)

        transport.channel.continuation.finish(throwing: ExecError("Disconnected"))
        try await wait { desktop.frontendID == nil }
        try expect(desktop.enabled.isEmpty && desktop.error != nil)
        try expect(permissionRequests == 1 && captureCount == 1)

        let requests = await transport.requests.requests
        try expect(!requests.contains { $0.path.hasSuffix("/desktop") })
        let permissionWrites = requests.filter { $0.path == "/v1/native/permission" }
        try expect(permissionWrites.count == 1 && permissionWrites[0].method == "PUT")
        let permissionBody = try JSONDecoder().decode(AgentJSON.self, from: permissionWrites[0].body!)
        try expect(permissionBody == .object(["frontendID": .string(frontend), "granted": .bool(true)]))
        let replies = requests.filter { $0.path == "/v1/native/results" }
        try expect(replies.count == 1 && replies[0].method == "POST")
        let reply = try JSONDecoder().decode(AgentJSON.self, from: replies[0].body!)
        try expect(reply["request"] == captureRequest)
        try expect(reply["result"] == .object([
            "type": .string("windows"),
            "windows": .array([.object(["id": .number(42), "title": .string("Test window")])])]))
    }

    func invalidRemoteBindingsFailClosedWithoutCapture() async throws {
        let frontend = "11111111-2222-4333-8444-555555555555"
        let conversation = AgentIntegrationTests.conversationID
        let invalidBindings = [
            binding(frontend: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", conversation: .string(conversation.uuidString)),
            binding(frontend: frontend, conversation: .string("not-a-uuid")),
            binding(frontend: frontend, conversation: .null)
        ]
        for invalidBinding in invalidBindings {
            let transport = ControlledAgentTransport()
            var permissionRequests = 0, captureCount = 0
            let desktop = AgentDesktop(api: AgentAPI(transport: transport), preflight: { true }, requestPermission: {
                permissionRequests += 1; return true
            }, capture: { _ in
                captureCount += 1
                return .init(text: "Must not capture", windows: [])
            })
            defer { desktop.stop() }
            try transport.emit(.object(["type": .string("registered"), "frontendID": .string(frontend)]))
            try await desktop.start()
            try transport.emit(binding(frontend: frontend, conversation: .string(conversation.uuidString)))
            try await wait { desktop.enabled.contains(conversation) }

            // Even an already enabled conversation must not capture after an invalid binding.
            try transport.emit(invalidBinding)
            try transport.emit(.object(["type": .string("request"),
                                        "request": request(frontend: frontend, conversation: conversation)]))
            try await wait { desktop.frontendID == nil }
            try expect(desktop.error != nil && desktop.enabled.isEmpty)
            try expect(permissionRequests == 0 && captureCount == 0)
            let requests = await transport.requests.requests
            try expect(requests.isEmpty)
        }
    }
}
