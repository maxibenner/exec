import AppKit
import Network

@MainActor final class OAuthCallback {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var connections: [NWConnection] = []
    private var timeout: Task<Void, Never>?
    private var redirectURI = ""

    func receive(state: String, redirectURI: String, authorize: @escaping @Sendable () -> URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    guard let url = URLComponents(string: redirectURI), url.scheme == "http",
                          ["localhost", "127.0.0.1"].contains(url.host ?? ""),
                          let portNumber = url.port, let rawPort = UInt16(exactly: portNumber),
                          let port = NWEndpoint.Port(rawValue: rawPort) else {
                        throw ExecError("Invalid local sign-in callback address.")
                    }
                    self.redirectURI = redirectURI
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] status in
                        Task { @MainActor in
                            guard let self, self.continuation != nil else { return }
                            switch status {
                            case .ready:
                                if !NSWorkspace.shared.open(authorize()) {
                                    self.finish(.failure(ExecError("Could not open the sign-in browser.")))
                                }
                            case .failed:
                                self.finish(.failure(ExecError("Could not start the local sign-in listener. Close any other sign-in using port 1455 and try again.")))
                            default: break
                            }
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in
                        Task { @MainActor in
                            guard let self, self.continuation != nil else { connection.cancel(); return }
                            guard self.connections.count < 16 else { connection.cancel(); return }
                            self.connections.append(connection)
                            connection.start(queue: .main)
                            self.read(connection, data: Data(), state: state)
                        }
                    }
                    listener.start(queue: .main)
                    timeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(180)) } catch { return }
                        self?.finish(.failure(ExecError("Sign-in timed out. Please try again.")))
                    }
                } catch { finish(.failure(error)) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func read(_ connection: NWConnection, data: Data, state: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, done, error in
            Task { @MainActor in
                guard let self, self.continuation != nil else { connection.cancel(); return }
                let buffer = data + (chunk ?? Data())
                guard buffer.count <= 16384, error == nil else { connection.cancel(); return }
                guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if done { connection.cancel() } else { self.read(connection, data: buffer, state: state) }
                    return
                }
                let line = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard line.count == 3, line[0] == "GET",
                      let url = Self.validatedURL(target: String(line[1]), redirectURI: self.redirectURI, state: state) else {
                    connection.cancel(); return
                }
                let body = "Sign-in received. You can return to Exec."
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in
                    Task { @MainActor in self.finish(.success(url)) }
                })
            }
        }
    }

    nonisolated static func validatedURL(target: String, redirectURI: String, state: String) -> URL? {
        guard let redirect = URLComponents(string: redirectURI),
              target.hasPrefix(redirect.path + "?"),
              var result = URLComponents(string: target), result.fragment == nil,
              result.path == redirect.path,
              let items = result.queryItems,
              Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "state" })?.value == state else { return nil }
        result.scheme = redirect.scheme
        result.host = redirect.host
        result.port = redirect.port
        return result.url
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }; connections.removeAll()
        continuation.resume(with: result)
    }
}
