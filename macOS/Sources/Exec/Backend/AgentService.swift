import AppKit
import Observation

@MainActor @Observable final class AgentService {
    static var profile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exec/Agent", isDirectory: true)
    }
    static var hasSavedSessions: Bool {
        let directory = profile.appendingPathComponent("conversations")
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.contains {
            $0.hasSuffix(".json") && UUID(uuidString: String($0.dropLast(5))) != nil
        } == true
    }
    private var process: Process?
    private(set) var api: AgentAPI?

    func start() async throws -> AgentAPI {
        if let api, process?.isRunning == true { return api }
        let socket = Self.profile.appendingPathComponent("service.sock").path
        guard socket.utf8.count <= 100 else { throw ExecError("The Exec backend profile path is too long for a local socket.") }
        guard !FileManager.default.fileExists(atPath: socket) else {
            throw ExecError("The Exec backend profile is already in use or was not shut down cleanly. Verify that the previous backend and its tools have stopped before recovering its socket and lock.")
        }
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("exec-agent"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ExecError("The bundled Exec backend is missing. Rebuild or reinstall Exec.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--profile", Self.profile.path, "serve", "--workspace-tools",
                             "--native-frontend-pid", String(ProcessInfo.processInfo.processIdentifier)]
        var environment = ProcessInfo.processInfo.environment
        // GUI onboarding always controls this app's private profile, never ambient shell credentials.
        environment.removeValue(forKey: "DEEPSEEK_API_KEY")
        environment.removeValue(forKey: "OPENAI_SESSION_JSON")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !FileManager.default.fileExists(atPath: socket) {
                try Task.checkCancellation()
                guard process.isRunning else { throw ExecError("The Exec backend could not start. Its profile may be locked or unreadable; no files were removed.") }
                guard ContinuousClock.now < deadline else { throw ExecError("The Exec backend did not become ready.") }
                try await Task.sleep(for: .milliseconds(25))
            }
            let api = AgentAPI(transport: UnixAgentTransport(socketPath: socket))
            let health = try await api.get("/v1/health")
            guard health["version"].number == 1, health["toolsEnabled"].bool else { throw ExecError("The bundled backend has an incompatible API or disabled workspace tools.") }
            self.api = api
            try await api.desktop.start()
            return api
        } catch {
            await shutdown()
            throw error
        }
    }

    /// SIGTERM asks Rust to cancel, reap tools and checkpoint. Never force kill or steal locks.
    func shutdown() async {
        api?.desktop.stop()
        guard let process else { return }
        if process.isRunning { process.terminate() }
        while process.isRunning { try? await Task.sleep(for: .milliseconds(25)) }
        self.process = nil
        api = nil
    }
}

@MainActor final class AgentAPI {
    let transport: any AgentTransport
    lazy var desktop = AgentDesktop(api: self)
    init(transport: any AgentTransport) { self.transport = transport }
    func get(_ path: String) async throws -> AgentJSON { try await request("GET", path) }
    func request(_ method: String, _ path: String, _ body: AgentJSON? = nil) async throws -> AgentJSON {
        let data = try await transport.request(method, path, body: try body.map { try JSONEncoder().encode($0) })
        do { return try JSONDecoder().decode(AgentJSON.self, from: data) }
        catch { throw ExecError("The backend returned an invalid response. The request was not retried.") }
    }
    func send<T: Encodable>(_ method: String, _ path: String, body: T) async throws -> AgentJSON {
        let data = try await transport.request(method, path, body: JSONEncoder().encode(body))
        return try JSONDecoder().decode(AgentJSON.self, from: data)
    }
    func snapshot(_ id: UUID) async throws -> AgentSnapshot {
        try await get(Self.path(id)).decoded(AgentSnapshot.self)
    }
    static func path(_ id: UUID, _ suffix: String = "") -> String { "/v1/conversations/\(id.uuidString.lowercased())\(suffix)" }
    func stream(_ id: UUID) -> AsyncThrowingStream<Data, Error> { transport.events("GET", Self.path(id, "/events"), body: nil) }
}
