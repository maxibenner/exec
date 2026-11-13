import AppKit
import Network

@MainActor struct HTTPConsumerTests {
    func redirectsAndInterruptedMutationsAreNotReplayed() async throws {
        for redirect in [false, true] {
            let peer = try HTTPTestPeer(redirect: redirect)
            defer { peer.close() }
            let port = try await peer.port()
            let api = AgentAPI(transport: HTTPAgentTransport(port: port, token: AgentIntegrationTests.apiToken,
                                                            nativeToken: AgentIntegrationTests.nativeToken))
            var failed = false
            do { _ = try await api.request("POST", "/v1/conversations", .object([:])) }
            catch { failed = true }
            try expect(failed)
            try await Task.sleep(for: .milliseconds(100))
            try expect(peer.requests.count == 1)
            let request = peer.requests[0]
            try expect(request.contains("Authorization: Bearer \(AgentIntegrationTests.apiToken)"))
            try expect(!request.contains("X-Exec-Native-Token"))
            // The synthetic Location points back at the same listener: following it would be observable.
            try expect(request.hasPrefix("POST /v1/conversations HTTP/1.1"))
        }
    }

    func tlsRejectsUntrustedCertificate() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("exec-tls-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = root.appendingPathComponent("key.pem").path
        let cert = root.appendingPathComponent("cert.pem").path
        let generate = Process()
        generate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        generate.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                              "-subj", "/CN=localhost", "-days", "1"]
        generate.environment = ["PATH": "/usr/bin:/bin"]
        generate.standardOutput = FileHandle.nullDevice
        generate.standardError = FileHandle.nullDevice
        try generate.run()
        while generate.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        try expect(generate.terminationStatus == 0)
        // Reserve an ephemeral port without touching a user's running service. A bind race fails the test.
        let reservation = try HTTPTestPeer(redirect: false)
        let port = try await reservation.port()
        try await reservation.closeAndWait()
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        // Apple's LibreSSL accepts only a port here. This short-lived dummy server
        // serves a generated certificate/status page, never the agent or real credentials.
        server.arguments = ["s_server", "-accept", String(port), "-cert", cert, "-key", key, "-www"]
        server.environment = ["PATH": "/usr/bin:/bin"]
        let output = Pipe()
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        try expect(flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0)
        var readiness = Data()
        for _ in 0..<300 {
            var bytes = [UInt8](repeating: 0, count: 256)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 { readiness.append(contentsOf: bytes.prefix(count)) }
            if String(decoding: readiness, as: UTF8.self).contains("ACCEPT") { break }
            try expect(server.isRunning)
            try await Task.sleep(for: .milliseconds(10))
        }
        try expect(String(decoding: readiness, as: UTF8.self).contains("ACCEPT"))
        let transport = HTTPAgentTransport(host: "localhost", port: port, usesTLS: true, token: AgentIntegrationTests.apiToken)
        var rejected = false
        do { _ = try await transport.request("GET", "/v1/health", body: nil) }
        catch { rejected = true }
        try expect(rejected) // No Keychain trust edits, insecure verification callback, or HTTP fallback.
    }
}

/// Tiny TCP fixture, not a second API implementation. Reads one bounded synthetic request,
/// then drops it after acceptance or sends a redirect. Never contacts a provider.
@MainActor private final class HTTPTestPeer {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private(set) var requests: [String] = []
    private var ready = false
    private var failed = false
    private var cancelled = false
    private let redirect: Bool
    init(redirect: Bool) throws {
        self.redirect = redirect
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.ready = true }
                if case .failed = state { self?.failed = true }
                if case .cancelled = state { self?.cancelled = true }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection, data: Data())
            }
        }
        listener.start(queue: .main)
    }
    func port() async throws -> UInt16 {
        for _ in 0..<200 {
            if ready, let port = listener.port?.rawValue { return port }
            if failed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "HTTP test listener did not start")
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] bytes, _, ended, _ in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var data = data
                if let bytes { data.append(bytes) }
                guard data.count <= 8192 else { connection.cancel(); return }
                if let boundary = data.range(of: Data("\r\n\r\n".utf8)), data.count >= boundary.upperBound + 2 {
                    self.requests.append(String(decoding: data, as: UTF8.self))
                    if self.redirect, let port = self.listener.port?.rawValue {
                        let response = Data("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(port)/v1/stolen\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    } else { connection.cancel() }
                } else if !ended { self.receive(connection, data: data) }
                else { connection.cancel() }
            }
        }
    }
    func closeAndWait() async throws {
        close()
        for _ in 0..<200 {
            if cancelled { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "HTTP test listener did not release its port")
    }
    func close() { listener.cancel(); connections.forEach { $0.cancel() } }
}
