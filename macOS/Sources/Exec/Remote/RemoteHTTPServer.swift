import Foundation
import Network

struct RemoteHTTPRequest: Sendable {
    let method: String
    let path: String
    var headers: [String: String] = [:]
    var body = Data()

    // Deliberately one request per connection. Reject ambiguous framing rather
    // than implementing chunking, pipelining, upgrades or proxy forwarding.
    static func parse(_ data: Data) throws -> Self? {
        guard data.count <= 73_728 else { throw ExecError("Request too large.") }
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 8192 else { throw ExecError("Headers too large.") }
            return nil
        }
        guard end.upperBound <= 8192, let text = String(data: data[..<end.lowerBound], encoding: .utf8) else {
            throw ExecError("Invalid headers.")
        }
        let lines = text.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, ["GET", "POST"].contains(start[0]), start[2] == "HTTP/1.1",
              start[1].hasPrefix("/"), !start[1].contains("?"), !start[1].contains("#") else {
            throw ExecError("Invalid request.")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw ExecError("Invalid header.") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 || (48...57).contains($0) }),
                  headers[name] == nil else { throw ExecError("Invalid or duplicate header.") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw ExecError("Invalid header value.") }
            headers[name] = value
        }
        guard let host = headers["host"], !host.isEmpty,
              headers["transfer-encoding"] == nil, headers["expect"] == nil,
              headers["upgrade"] == nil else { throw ExecError("Unsupported request framing.") }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(rawLength), length <= 65_536,
              start[0] != "GET" || length == 0 else { throw ExecError("Invalid content length.") }
        let size = end.upperBound + length
        guard data.count <= size else { throw ExecError("Pipelining is not supported.") }
        guard data.count == size else { return nil }
        return Self(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(data[end.upperBound...]))
    }
}

struct RemoteHTTPResponse: Sendable {
    var status = 200
    var contentType = "application/json; charset=utf-8"
    var body = Data()
    var etag: String?

    static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self(status: status, body: try encoder.encode(value))
    }

    static func error(_ status: Int, _ message: String) -> Self {
        struct Failure: Encodable { let error: String }
        return (try? json(Failure(error: message), status: status)) ?? Self(status: 500)
    }

    var bytes: Data {
        let reason = [200: "OK", 202: "Accepted", 304: "Not Modified", 400: "Bad Request", 401: "Unauthorized",
                      403: "Forbidden", 404: "Not Found", 409: "Conflict", 413: "Content Too Large",
                      500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Error"
        var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\n"
        if status != 304 { header += "Content-Length: \(body.count)\r\n" }
        header += "Connection: close\r\nX-Exec-Response: 1\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n"
        header += "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n"
        if let etag { header += "ETag: \(etag)\r\n" }
        return Data((header + "\r\n").utf8) + body
    }
}

/// Bounded loopback HTTP transport. It never knows about conversations or connector credentials.
@MainActor final class RemoteHTTPServer {
    private struct Client {
        let connection: NWConnection
        var timeout: Task<Void, Never>?
        var request: Task<Void, Never>?
    }
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var generation = UUID()
    private let handle: @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse
    private let stateChanged: @MainActor (UInt16?, String?) -> Void

    init(handle: @escaping @MainActor (RemoteHTTPRequest) async -> RemoteHTTPResponse,
         stateChanged: @escaping @MainActor (UInt16?, String?) -> Void) {
        self.handle = handle
        self.stateChanged = stateChanged
    }

    func start(port: UInt16) throws {
        stop()
        let generation = self.generation
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch state {
                case .ready: self.stateChanged(listener.port?.rawValue, nil)
                case .failed:
                    self.stop()
                    self.stateChanged(nil, "Could not listen on the mobile access port. Check whether another app is using it.")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == generation, self.clients.count < 24 else { connection.cancel(); return }
                let id = UUID()
                self.clients[id] = Client(connection: connection)
                self.clients[id]?.timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    self?.close(id)
                }
                connection.start(queue: .main)
                self.read(id, buffer: Data())
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        generation = UUID()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for id in Array(clients.keys) { close(id) }
    }

    private func close(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timeout?.cancel()
        client.request?.cancel()
        client.connection.cancel()
        // Accepted agent turns belong to ChatStore, not the HTTP request task.
    }

    private func read(_ id: UUID, buffer: Data) {
        guard let client = clients[id] else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, done, error in
            Task { @MainActor in
                guard let self, self.clients[id] != nil else { return }
                guard error == nil else { self.close(id); return }
                let buffer = buffer + (chunk ?? Data())
                do {
                    if let request = try RemoteHTTPRequest.parse(buffer) {
                        self.clients[id]?.request = Task { [weak self] in
                            guard let self else { return }
                            let response = await self.handle(request)
                            self.send(response, to: id)
                        }
                    } else if done { self.close(id) }
                    else { self.read(id, buffer: buffer) }
                } catch { self.send(.error(400, "Invalid HTTP request."), to: id) }
            }
        }
    }

    private func send(_ response: RemoteHTTPResponse, to id: UUID) {
        guard let client = clients[id] else { return }
        client.connection.send(content: response.bytes, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }
}
