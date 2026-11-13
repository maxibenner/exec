import AppKit
import Foundation

actor FakeAgentTransport: AgentTransport {
    struct Request: Sendable { let method: String; let path: String; let body: Data? }
    private(set) var requests: [Request] = []
    private var replies: [String: Data] = [:]
    private var failures: Set<String> = []
    func reply(_ path: String, _ value: AgentJSON) throws { replies[path] = try JSONEncoder().encode(value) }
    func fail(_ path: String) { failures.insert(path) }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        requests.append(Request(method: method, path: path, body: body))
        if failures.contains(path) { throw ExecError("Connection interrupted after acceptance. Not retried.") }
        return replies[path] ?? Data("{}".utf8)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { _ in }
    }
}

@MainActor struct AgentIntegrationTests {
    static let conversationID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let operationID = UUID(uuidString: "abcdefab-2222-4222-8222-222222222222")!
    static let approvalID = UUID(uuidString: "abcdefab-3333-4333-8333-333333333333")!
    static let userID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    static let assistantID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    static let toolID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    static func fixture(state: String = "awaiting_approval", result: Bool = false) throws -> AgentJSON {
        let json = """
        {"id":"\(conversationID)","model":"deepseek/test","workspace":"/tmp",
         "configuration":{"settings":{"systemPrompt":"Keep this prompt","autoApprove":false,"effort":null,"searchModel":null},"instructionsFrozen":true,"workspaceInstructions":null},
         "metadata":{"title":"Test session","manuallyNamed":false,"activityAt":1000},
         "messages":[{"id":"\(userID)","role":"user","text":"Run tests"},
          {"id":"\(assistantID)","role":"assistant","text":"Checking…","status":"completed","calls":[{"id":"call-one","name":"shell","arguments":{"command":"printf hello","description":"Run the local test","timeout_seconds":10}}]}\(result ? ",{\"id\":\"\(toolID)\",\"role\":\"tool\",\"callID\":\"call-one\",\"text\":\"Denied\",\"outcome\":\"denied\",\"details\":null}" : "")],
         "pendingInput":[],"operation":{"id":"\(operationID)","state":"\(state)"},
         "approval":\(result ? "null" : "{\"id\":\"\(approvalID)\",\"operationID\":\"\(operationID)\",\"call\":{\"id\":\"call-one\",\"name\":\"shell\",\"arguments\":{\"command\":\"printf hello\",\"timeout_seconds\":10}},\"description\":\"Run shell command\",\"details\":null,\"workspace\":\"/tmp\"}"),
         "activeToolCallID":null,"storageError":null,"contextUsage":{"tokens":120,"limit":1000}}
        """
        return try JSONDecoder().decode(AgentJSON.self, from: Data(json.utf8))
    }
    static let apiToken = String(repeating: "1", count: 64)
    static let nativeToken = String(repeating: "2", count: 64)
    func httpConfiguration() throws {
        let configuration = try AgentHTTPConfiguration()
        let another = try AgentHTTPConfiguration()
        try expect(configuration.host == "127.0.0.1" && configuration.port == 8765)
        try expect(configuration.token.count == 64 && configuration.nativeToken.count == 64)
        try expect(configuration.token != configuration.nativeToken && configuration.token != another.token)
        let environment = configuration.childEnvironment(inherited: [
            "PATH": "/usr/bin:/bin", "HOME": "/isolated-home",
            "EXEC_AGENT_URL": "https://other-backend.example", "EXEC_AGENT_HOST": "0.0.0.0",
            "EXEC_AGENT_PORT": "19876", "EXEC_AGENT_INSECURE_NO_AUTH": "1",
            "EXEC_AGENT_ALLOW_INSECURE_HTTP": "1", "EXEC_AGENT_TOKEN": Self.apiToken,
            "EXEC_AGENT_NATIVE_TOKEN": Self.nativeToken,
            "DEEPSEEK_API_KEY": "test-only", "OPENAI_SESSION_JSON": "test-only"])
        try expect(environment == ["PATH": "/usr/bin:/bin", "HOME": "/isolated-home",
                                   "EXEC_AGENT_TOKEN": configuration.token,
                                   "EXEC_AGENT_NATIVE_TOKEN": configuration.nativeToken])
        try expect(configuration.transport.host == "127.0.0.1" && configuration.transport.port == 8765)
        try expect(configuration.transport.token == configuration.token && !configuration.transport.usesTLS)
    }

    func snapshotAndApproval() async throws {
        let transport = FakeAgentTransport()
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        let store = ChatStore(provider: provider)
        defer { store.closePresentation() }
        let first = try Self.fixture().decoded(AgentSnapshot.self)
        try store.apply(first)
        try expect(store.messages.count == 3)
        try expect(store.messages[0].id == Self.userID)
        try expect(store.messages[2].pendingTool?.isAwaitingApproval == true)
        try expect(store.busy && store.isSending && !store.canFork)
        try expect(store.contextUsage?.percent == 12)
        try expect(store.tools.pendingApproval?.content == "printf hello")
        try expect(store.tools.pendingApproval?.timeoutSeconds == 10)
        let rowID = store.messages[2].id
        try store.apply(first)
        try expect(store.messages.count == 3 && store.messages[2].id == rowID)
        store.tools.resolveApproval(id: Self.approvalID, approved: false)
        store.tools.resolveApproval(id: Self.approvalID, approved: true)
        for _ in 0..<100 {
            if await transport.requests.count > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = await transport.requests
        try expect(requests.count == 1)
        let decision = try JSONDecoder().decode(AgentJSON.self, from: requests[0].body!)
        try expect(decision["operationID"].string == Self.operationID.uuidString.lowercased())
        try expect(decision["approvalID"].string == Self.approvalID.uuidString.lowercased())
        try expect(!decision["approved"].bool)
        try store.apply(Self.fixture(state: "completed", result: true).decoded(AgentSnapshot.self))
        try expect(!store.busy && store.canFork && store.tools.pendingApproval == nil)
        try expect(store.messages[2].id == rowID && store.messages[2].toolResult?.outcome == "denied")
        try expect(store.messages[2].pendingTool == nil)
        try expect(store.messages[2].toolResult?.call.arguments.contains("printf hello") == true)
        try expect(store.systemPrompt == "Keep this prompt")
    }

    func uncertainSendIsNotRetried() async throws {
        let transport = FakeAgentTransport()
        try await transport.reply("/v1/providers", .array([.object(["id": .string("deepseek"), "name": .string("DeepSeek"), "connected": .bool(true)])]))
        let snapshot = try Self.fixture(state: "completed", result: true)
        try await transport.reply(AgentAPI.path(Self.conversationID), snapshot)
        await transport.fail(AgentAPI.path(Self.conversationID, "/turns"))
        let provider = AgentAccounts(api: AgentAPI(transport: transport))
        try await provider.refreshConnections()
        let store = ChatStore(provider: provider)
        defer { store.closePresentation() }
        try store.apply(snapshot.decoded(AgentSnapshot.self))
        store.installModels([ChatModel(id: "deepseek/test", name: "Test")])
        store.draft = "Another message"
        store.send()
        await store.waitUntilIdle()
        try expect(store.error?.contains("Not retried") == true)
        try expect(store.draft == "Another message")
        let submissions = await transport.requests.filter { $0.path.hasSuffix("/turns") }
        try expect(submissions.count == 1)
    }

    func quitWaitsForBackendAndPreservesCopy() async throws {
        let transport = FakeAgentTransport()
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)))
        try library.current.apply(Self.fixture().decoded(AgentSnapshot.self))
        defer { library.closePresentations() }
        let delegate = AppDelegate()
        delegate.store = library
        var alertText = ""
        var alertTitle = ""
        var buttonTitles: [String] = []
        var decision: CheckedContinuation<NSApplication.ModalResponse, Never>?
        var shutdown: CheckedContinuation<Void, Never>?
        var replies: [Bool] = []
        delegate.confirmQuit = { alert, _ in
            alertTitle = alert.messageText
            buttonTitles = alert.buttons.map(\.title)
            alertText = alert.informativeText
            return await withCheckedContinuation { decision = $0 }
        }
        delegate.shutdownBackend = { await withCheckedContinuation { shutdown = $0 } }
        delegate.replyToTermination = { _, value in replies.append(value) }
        try expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        await Task.yield()
        try expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        decision?.resume(returning: .alertSecondButtonReturn); decision = nil
        for _ in 0..<10 { await Task.yield() }
        try expect(replies == [false])
        try expect(alertTitle == "Quit Exec?" && buttonTitles == ["Quit", "Cancel"])
        try expect(alertText == "Active operations in all conversations will be stopped. Saved conversations will be kept.")
        try expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        for _ in 0..<10 { await Task.yield() }
        decision?.resume(returning: .alertFirstButtonReturn); decision = nil
        for _ in 0..<10 { await Task.yield() }
        try expect(replies == [false] && shutdown != nil)
        shutdown?.resume(); shutdown = nil
        for _ in 0..<10 { await Task.yield() }
        try expect(replies == [false, true])
    }

    private func wait(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure(description: "Timed out waiting for navigation")
    }

    /// Real Rust subprocess and network-bound HTTP framing, isolated empty credentials/profile.
    /// Never configures a provider or sends a live model request.
    func realService() async throws {
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/agent-rust/release/exec-agent")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw CheckFailure(description: "Build the Rust helper before running integration checks.") }
        let root = URL(fileURLWithPath: "/tmp/exec-agent-test-\(UUID().uuidString.prefix(8))")
        let profile = root.appendingPathComponent("profile")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--profile", profile.path, "--workspace-tools", "--port", "18765"]
        process.environment = ["PATH": "/usr/bin:/bin", "EXEC_AGENT_TOKEN": Self.apiToken, "EXEC_AGENT_NATIVE_TOKEN": Self.nativeToken]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        try await AgentService.waitUntilReady(process: process, output: output)
        let api = AgentAPI(transport: HTTPAgentTransport(host: "127.0.0.1", port: 18765, token: Self.apiToken, nativeToken: Self.nativeToken))
        let health = try await api.get("/v1/health")
        try expect(health["version"].number == 1)
        for transport in [HTTPAgentTransport(port: 18765), HTTPAgentTransport(port: 18765, token: Self.nativeToken)] {
            var rejected = false
            do { _ = try await AgentAPI(transport: transport).get("/v1/health") }
            catch { rejected = true; try expect(!error.localizedDescription.contains(Self.apiToken)) }
            try expect(rejected)
        }
        let ordinary = AgentAPI(transport: HTTPAgentTransport(port: 18765, token: Self.apiToken))
        var nativeRejected = false
        do { _ = try await ordinary.request("POST", "/v1/native/events", .object(["osScreenPermission": .bool(true)])) }
        catch { nativeRejected = true }
        try expect(nativeRejected)
        // A conflicting helper must fail readiness, not attach to the first backend.
        let conflict = Process()
        conflict.executableURL = executable
        let conflictProfile = root.appendingPathComponent("conflict-profile")
        conflict.arguments = ["--profile", conflictProfile.path, "--port", "18765"]
        conflict.environment = ["PATH": "/usr/bin:/bin", "EXEC_AGENT_TOKEN": Self.apiToken]
        let conflictOutput = Pipe()
        conflict.standardOutput = conflictOutput
        conflict.standardError = FileHandle.nullDevice
        try conflict.run()
        defer { if conflict.isRunning { conflict.terminate(); conflict.waitUntilExit() } }
        var rejected = false
        do { try await AgentService.waitUntilReady(process: conflict, output: conflictOutput) }
        catch { rejected = true }
        try expect(rejected && !conflict.isRunning && conflict.terminationStatus != 0)
        try expect(!FileManager.default.fileExists(atPath: conflictProfile.appendingPathComponent("conversations/.lock").path))
        let stillHealthy = try await api.get("/v1/health")
        try expect(stillHealthy["version"].number == 1)
        let accounts = AgentAccounts(api: api)
        try await accounts.refreshConnections()
        try expect(accounts.connections.count == 2 && accounts.account == nil)
        let value = try await api.request("POST", "/v1/conversations", .object([
            "model": .string("deepseek/test"), "workspace": .string(workspace.path),
            "settings": .object(["autoApprove": .bool(false), "systemPrompt": .string("Test instructions")])]))
        let snapshot = try value.decoded(AgentSnapshot.self)
        // Native registration uses HTTP; OS access/capture remain isolated fakes.
        let desktop = AgentDesktop(api: api, preflight: { true }, requestPermission: { false }, capture: { _ in
            throw CheckFailure(description: "No screen capture expected in isolated service check")
        })
        try await desktop.start()
        defer { desktop.stop() }
        try expect(desktop.frontendID != nil && desktop.enabled.isEmpty)
        try await desktop.setEnabled(true, for: snapshot.id)
        let permission = try await api.get(AgentAPI.path(snapshot.id, "/desktop"))
        try expect(permission["enabled"].bool)
        try expect(permission["frontendID"].string == desktop.frontendID)
        try expect(snapshot.configuration.settings.autoApprove == false)
        try expect(snapshot.configuration.settings.systemPrompt == "Test instructions")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        let image = try await api.request("POST", AgentAPI.path(snapshot.id, "/images"), .object([
            "name": .string("Test.png"), "base64": .string(png.base64EncodedString())])).decoded(AgentImage.self)
        let encoded = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(image))
        try expect(encoded["id"].string == image.id.uuidString.lowercased())
        let loadedImage = try await api.get("/v1/images/\(image.id.uuidString.lowercased())")
        try expect(loadedImage["base64"].string.flatMap { Data(base64Encoded: $0) } == png)
        _ = try await api.request("DELETE", AgentAPI.path(snapshot.id, "/images/\(image.id.uuidString.lowercased())"))
        let store = ChatStore(provider: accounts)
        try await store.loadSession(snapshot.id)
        defer { store.closePresentation() }
        let stream = api.stream(snapshot.id)
        var iterator = stream.makeAsyncIterator()
        let frame = try await iterator.next()
        let event = try JSONDecoder().decode(AgentEvent.self, from: frame!)
        try expect(event.snapshot?.id == snapshot.id)
        _ = try await api.request("PUT", AgentAPI.path(snapshot.id, "/title"), .object(["title": .string("Renamed")]))
        let catalog = try await api.get("/v1/conversations").array.map(SessionSummary.init)
        try expect(catalog.count == 1 && catalog[0].title == "Renamed")
        _ = try await api.send("PUT", AgentAPI.path(snapshot.id, "/settings"), body: AgentSettings(systemPrompt: "Updated", autoApprove: true))
        let fork = try await api.request("POST", AgentAPI.path(snapshot.id, "/fork"), .object([:])).decoded(AgentSnapshot.self)
        try expect(fork.id != snapshot.id && fork.configuration.settings.systemPrompt == "Updated")
        let forkPermission = try await api.get(AgentAPI.path(fork.id, "/desktop"))
        try expect(!forkPermission["enabled"].bool)
        try await desktop.setEnabled(false, for: snapshot.id)
        let revoked = try await api.get(AgentAPI.path(snapshot.id, "/desktop"))
        try expect(!revoked["enabled"].bool)
        let config = AgentLibraryConfiguration(defaultModel: "deepseek/test", settings: .init(), order: [fork.id, snapshot.id])
        _ = try await api.send("PUT", "/v1/library", body: config)
        let restored = try await api.get("/v1/library").decoded(AgentLibraryConfiguration.self)
        try expect(restored.order == [fork.id, snapshot.id])
        let suite = "exec-agent-navigation-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = ChatLibrary(provider: accounts, preferences: preferences)
        defer { library.closePresentations() }
        try await library.restore()
        library.openSession(snapshot.id)
        try await wait { !library.navigating && library.currentSessionID == snapshot.id }
        let original = library.current
        original.draft = "Keep my draft"
        library.detachSession(snapshot.id) { detached in assert(detached === original) }
        try expect(library.detachedSessionIDs.contains(snapshot.id) && library.current !== original)
        library.openSession(fork.id)
        try await wait { !library.navigating && library.currentSessionID == fork.id }
        let main = library.current
        library.deleteSession(snapshot.id)
        try await wait { !library.navigating }
        try expect(library.current === main && !library.detachedSessionIDs.contains(snapshot.id))
        try expect(original.draft == "Keep my draft")
        // Use the surviving fork for the disconnected-provider turn below.
        // No configured credential: Rust fails safely, retaining input without inference.
        _ = try await api.request("POST", AgentAPI.path(fork.id, "/turns"), .object(["text": .string("No live inference")]))
        var terminal: AgentSnapshot?
        for _ in 0..<100 {
            let state = try await api.snapshot(fork.id)
            if state.operation?.active == false { terminal = state; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(terminal?.operation?.state == "failed")
        try expect(terminal?.messages.first?.text == "No live inference")
        _ = try await api.request("DELETE", AgentAPI.path(fork.id))
        library.closePresentations()
        store.closePresentation()
        process.terminate()
        while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        try expect(process.terminationStatus == 0)
        try expect(!FileManager.default.fileExists(atPath: profile.appendingPathComponent("conversations/.lock").path))
    }
}
