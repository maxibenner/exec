import Foundation

// Parsing and network consumption stay off the UI actor. Only semantic events
// cross the boundary; the provider retains opaque response data for follow-ups.
enum OpenAITransport {
    enum Event: Sendable {
        case text(String)
        case completed(Data)
    }

    static func stream(_ request: URLRequest) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try OpenAIHTTP.check(response)
                    var parser = SSEParser()
                    var completed = false
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let data = try parser.push(byte), let event = try decode(data) else { continue }
                        continuation.yield(event)
                        if case .completed = event { completed = true; break }
                    }
                    guard completed else { throw HarnessError("The response stream ended before completion.") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func decode(_ data: Data) throws -> Event? {
        let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        switch event["type"] as? String {
        case "response.output_text.delta", "response.refusal.delta":
            guard let delta = event["delta"] as? String else { throw HarnessError("Invalid text event.") }
            return .text(delta)
        case "response.completed", "response.done":
            guard let response = event["response"] as? [String: Any],
                  response["status"] as? String == "completed",
                  let output = response["output"] as? [[String: Any]] else {
                throw HarnessError("Invalid completion event.")
            }
            return .completed(try JSONSerialization.data(withJSONObject: output))
        case "response.failed", "response.incomplete", "error":
            let response = event["response"] as? [String: Any]
            let error = (response?["error"] as? [String: Any]) ?? (event["error"] as? [String: Any])
            let code = error?["code"] as? String ?? event["code"] as? String ?? "incomplete_response"
            throw HarnessError("OpenAI: \(code)")
        default: return nil
        }
    }
}

// Incremental SSE framing, independent of TCP chunk boundaries. Supports CRLF,
// multiline data, comments, and bounded event sizes.
struct SSEParser {
    private var line = Data()
    private var payload = Data()
    private var size = 0

    mutating func push(_ byte: UInt8) throws -> Data? {
        size += 1
        guard size <= 4 * 1024 * 1024 else { throw HarnessError("Stream event exceeded the size limit.") }
        guard byte == 10 else { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            size = 0
            guard !payload.isEmpty else { return nil }
            payload.removeLast()
            let event = payload
            payload = Data()
            return event
        }
        if line.starts(with: Data("data:".utf8)) {
            var value = line.dropFirst(5)
            if value.first == 32 { value = value.dropFirst() }
            payload.append(contentsOf: value)
            payload.append(10)
        }
        return nil
    }
}
