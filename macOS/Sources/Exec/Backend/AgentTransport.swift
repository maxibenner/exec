import Foundation
import Network

/// The only transport to the agent. Dropping an observer never cancels an operation.
/// Mutations are sent exactly once; neither transport failures nor HTTP errors retry.
protocol AgentTransport: Sendable {
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data
    func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error>
}

struct UnixAgentTransport: AgentTransport {
    let socketPath: String
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        let connection = AgentSocket(path: socketPath)
        return try await withTaskCancellationHandler {
            let timeout = Task {
                try await Task.sleep(for: .seconds(120))
                connection.cancel()
            }
            defer { timeout.cancel(); connection.cancel() }
            var reader = try await connection.open(method, path, body: body)
            var result = Data()
            while let bytes = try await reader.next() {
                guard result.count + bytes.count <= HTTPBodyReader.limit else { throw ExecError("The backend response exceeded 32 MiB.") }
                result.append(bytes)
            }
            try Self.validate(reader.status, data: result)
            return result
        } onCancel: { connection.cancel() }
    }

    func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        let connection = AgentSocket(path: socketPath)
        let events = AgentEventReader(connection: connection, method: method, path: path, body: body)
        // Consumer-driven reads: never accumulate a queue of large full snapshots,
        // and never drop token deltas merely because several arrive in one packet.
        return AsyncThrowingStream(unfolding: {
            try await withTaskCancellationHandler {
                try await events.next()
            } onCancel: { connection.cancel() }
        })
    }

    fileprivate static func validate(_ status: Int, data: Data) throws {
        guard (200..<300).contains(status) else {
            struct Failure: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            throw ExecError(message ?? "The backend request failed (HTTP \(status)).")
        }
    }
}

private actor AgentEventReader {
    let connection: AgentSocket
    let method: String
    let path: String
    let body: Data?
    private var reader: HTTPBodyReader?
    private var pending = Data()
    private var closed = false
    init(connection: AgentSocket, method: String, path: String, body: Data?) {
        self.connection = connection; self.method = method; self.path = path; self.body = body
    }
    func next() async throws -> Data? {
        guard !closed else { return nil }
        do {
            var reader: HTTPBodyReader
            if let existing = self.reader { reader = existing }
            else {
                reader = try await connection.open(method, path, body: body)
                if !(200..<300).contains(reader.status) {
                    var failure = Data()
                    while let bytes = try await reader.next() {
                        guard failure.count + bytes.count <= HTTPBodyReader.limit else { throw ExecError("The backend response exceeded 32 MiB.") }
                        failure.append(bytes)
                    }
                    try UnixAgentTransport.validate(reader.status, data: failure)
                }
            }
            while true {
                if let end = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<end])
                    pending.removeSubrange(...end)
                    guard line.count <= HTTPBodyReader.limit else { throw ExecError("The backend event exceeded 32 MiB.") }
                    if line.isEmpty { continue }
                    self.reader = reader
                    return line
                }
                guard pending.count <= HTTPBodyReader.limit else { throw ExecError("The backend event exceeded 32 MiB.") }
                guard let bytes = try await reader.next() else {
                    throw ExecError("The backend event stream was interrupted. Reopen this conversation to reconnect. Work may still be running.")
                }
                pending.append(bytes)
            }
        } catch {
            closed = true
            connection.cancel()
            throw error
        }
    }
}

/// NWConnection owns descriptor lifetime and makes cancellation safe during an async read.
private final class AgentSocket: @unchecked Sendable {
    let connection: NWConnection
    init(path: String) {
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }
    deinit { connection.cancel() }
    func cancel() { connection.cancel() }
    func open(_ method: String, _ path: String, body: Data?) async throws -> HTTPBodyReader {
        guard path.hasPrefix("/v1/"), !path.contains("\r"), !path.contains("\n") else { throw ExecError("Invalid backend request.") }
        connection.start(queue: DispatchQueue(label: "Exec.agent.socket"))
        let body = body ?? Data()
        var request = Data("\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        request.append(body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: request, completion: .contentProcessed { error in
                if error != nil { continuation.resume(throwing: ExecError("Could not reach the Exec backend. The request was not retried.")) }
                else { continuation.resume() }
            })
        }
        var reader = HTTPBodyReader(socket: self)
        try await reader.headers()
        return reader
    }
    func read() async throws -> Data {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete && error == nil { continuation.resume(returning: Data()) }
                else { continuation.resume(throwing: ExecError("The backend connection was interrupted. The request was not retried.")) }
            }
        }
    }
}

private struct HTTPBodyReader {
    static let limit = 32 * 1024 * 1024
    let socket: AgentSocket
    var buffer = Data()
    var status = 0
    var chunked = false
    var remaining: Int?
    var chunkRemaining = 0
    var finished = false

    mutating func line(maximum: Int = 16_384) async throws -> String {
        while true {
            if let range = buffer.range(of: Data([13, 10])) {
                guard range.lowerBound - buffer.startIndex <= maximum,
                      let value = String(data: buffer[..<range.lowerBound], encoding: .utf8) else { throw ExecError("Invalid backend HTTP framing.") }
                buffer.removeSubrange(..<range.upperBound)
                return value
            }
            guard buffer.count <= maximum else { throw ExecError("Invalid backend HTTP framing.") }
            let bytes = try await socket.read()
            guard !bytes.isEmpty else { throw ExecError("The backend response ended unexpectedly.") }
            buffer.append(bytes)
        }
    }
    mutating func headers() async throws {
        let start = try await line().split(separator: " ")
        guard start.count >= 2, start[0] == "HTTP/1.1", let code = Int(start[1]) else { throw ExecError("Invalid backend HTTP response.") }
        status = code
        var size = 0
        while true {
            let header = try await line()
            if header.isEmpty { break }
            size += header.utf8.count
            guard size <= 32_768 else { throw ExecError("Backend HTTP headers are too large.") }
            let parts = header.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { throw ExecError("Invalid backend HTTP header.") }
            let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            switch parts[0].lowercased() {
            case "content-length":
                guard remaining == nil, let length = Int(value), (0...Self.limit).contains(length) else { throw ExecError("Invalid backend response length.") }
                remaining = length
            case "transfer-encoding":
                guard value == "chunked", !chunked else { throw ExecError("Unsupported backend HTTP framing.") }
                chunked = true
            default: break
            }
        }
        guard !chunked || remaining == nil else { throw ExecError("Ambiguous backend HTTP framing.") }
    }
    mutating func next() async throws -> Data? {
        if finished { return nil }
        if chunked {
            if chunkRemaining == 0 {
                let size = try await line().split(separator: ";", maxSplits: 1).first
                guard let size, let count = Int(size, radix: 16), (0...Self.limit).contains(count) else { throw ExecError("Invalid backend HTTP chunk.") }
                if count == 0 {
                    // No application trailers are defined by this API.
                    guard try await line() == "" else { throw ExecError("Unexpected backend HTTP trailer.") }
                    finished = true
                    return nil
                }
                chunkRemaining = count
            }
            let data = try await take(upTo: chunkRemaining)
            chunkRemaining -= data.count
            if chunkRemaining == 0, try await line(maximum: 0) != "" { throw ExecError("Invalid backend HTTP chunk boundary.") }
            return data
        }
        if let count = remaining {
            if count == 0 { finished = true; return nil }
            let data = try await take(upTo: count)
            remaining = count - data.count
            return data
        }
        if !buffer.isEmpty { let data = buffer; buffer = Data(); return data }
        let data = try await socket.read()
        if data.isEmpty { finished = true; return nil }
        return data
    }
    mutating func take(upTo count: Int) async throws -> Data {
        if buffer.isEmpty { buffer = try await socket.read() }
        guard !buffer.isEmpty else { throw ExecError("The backend response ended unexpectedly.") }
        let data = Data(buffer.prefix(count))
        buffer.removeFirst(data.count)
        return data
    }
}
