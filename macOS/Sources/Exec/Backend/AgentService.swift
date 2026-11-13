import AppKit
import Observation
import Darwin

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
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("exec-agent"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ExecError("The bundled Exec backend is missing. Rebuild or reinstall Exec.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--profile", Self.profile.path, "--workspace-tools"]
        var environment = ProcessInfo.processInfo.environment
        // GUI onboarding always controls this app's private profile, never ambient shell credentials.
        environment.removeValue(forKey: "DEEPSEEK_API_KEY")
        environment.removeValue(forKey: "OPENAI_SESSION_JSON")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        do {
            try await Self.waitUntilReady(process: process, output: output)
            let api = AgentAPI(transport: HTTPAgentTransport())
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

    /// Wait for our child's readiness, not an arbitrary server already using the port.
    /// The marker carries no address: the endpoint is fixed and never discovered.
    static func waitUntilReady(process: Process, output: Pipe) async throws {
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw ExecError("Could not read backend readiness.")
        }
        defer { try? output.fileHandleForReading.close() }
        var marker = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while true {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw ExecError("The Exec backend could not start. Port 8765 may be in use or its profile may be locked or unreadable; no files were removed.")
            }
            var bytes = [UInt8](repeating: 0, count: 64)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 { marker.append(contentsOf: bytes.prefix(count)) }
            if marker == Data("ready\n".utf8) { return }
            guard marker.count < 64, count >= 0 || errno == EAGAIN || errno == EINTR else {
                throw ExecError("Invalid backend readiness response.")
            }
            guard ContinuousClock.now < deadline else { throw ExecError("The Exec backend did not become ready.") }
            try await Task.sleep(for: .milliseconds(25))
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
