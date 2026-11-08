import Foundation

// Parsing and network consumption stay off the UI actor. Only semantic events
// cross the boundary; the provider retains opaque response data for follow-ups.
enum OpenAITransport {
    enum Event: Sendable {
        case text(String)
        case completed(Data, usage: CodexResponseUsage)
    }

    static func stream(_ request: URLRequest, session: URLSession = OpenAIHTTP.session) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    defer { bytes.task.cancel() }
                    try await check(response, bytes: bytes, request: request)
                    var parser = SSEParser()
                    var decoder = ResponseDecoder()
                    var completed = false
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let data = try parser.push(byte), let event = try decoder.decode(data) else { continue }
                        continuation.yield(event)
                        if case .completed = event { completed = true; break }
                    }
                    guard completed else { throw ExecError("The response stream ended before completion.") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func boundedResponse(_ request: URLRequest, session: URLSession, maximumBytes: Int = 4 * 1024 * 1024) async throws -> Data {
        let task = Task.detached {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try await check(response, bytes: bytes, request: request)
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { throw ExecError("Provider response exceeded the size limit.") }
                data.append(byte)
            }
            return data
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    // Consume only a bounded error body. Successful SSE streams remain untouched.
    private static func check(_ response: URLResponse, bytes: URLSession.AsyncBytes, request: URLRequest) async throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else {
            try OpenAIHTTP.check(response)
            return
        }
        var body = Data()
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                body.append(byte)
                if body.count > 16 * 1024 { break }
            }
        } catch {
            try Task.checkCancellation()
            // A broken error body must not obscure the original HTTP status.
        }
        try Task.checkCancellation()
        try OpenAIHTTP.check(response, body: body, request: request)
    }

    static func decode(_ data: Data) throws -> Event? {
        var decoder = ResponseDecoder()
        return try decoder.decode(data)
    }

    // Codex can finish items individually and omit them from the terminal output.
    // Keep those completed items until the response itself succeeds; never execute
    // a tool just because its arguments or output_item.done event arrived.
    struct ResponseDecoder {
        private var items: [Int: [String: Any]] = [:]

        mutating func decode(_ data: Data) throws -> Event? {
            let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            switch event["type"] as? String {
            case "response.output_text.delta", "response.refusal.delta":
                guard let delta = event["delta"] as? String else { throw ExecError("Invalid text event.") }
                return .text(delta)
            case "response.output_item.done":
                guard let index = event["output_index"] as? Int, index >= 0, index < 256,
                      let item = event["item"] as? [String: Any] else {
                    throw ExecError("Invalid completed output item.")
                }
                items[index] = item
                _ = try serializedOutput()
                return nil
            case "response.completed", "response.done":
                guard let response = event["response"] as? [String: Any],
                      response["status"] as? String == "completed" else {
                    throw ExecError("Invalid completion event.")
                }
                if let rawOutput = response["output"] {
                    guard let output = rawOutput as? [[String: Any]], output.count <= 256 else {
                        throw ExecError("Invalid completion output.")
                    }
                    for (index, item) in output.enumerated() {
                        let id = item["id"] as? String
                        let matchingIndex = id.flatMap { id in items.first(where: { $0.value["id"] as? String == id })?.key }
                        let sameSlot = items[index] == nil ||
                            (items[index]?["id"] as? String == id && items[index]?["type"] as? String == item["type"] as? String)
                        let slot = matchingIndex ?? (sameSlot ? index : (items.keys.max() ?? -1) + 1)
                        items[slot] = (items[slot] ?? [:]).merging(item) { _, final in final }
                    }
                }
                return .completed(try serializedOutput(), usage: CodexResponseUsage(response: response))
            case "response.failed", "response.incomplete", "error":
                let response = event["response"] as? [String: Any]
                let error = (response?["error"] as? [String: Any]) ?? (event["error"] as? [String: Any])
                let code = error?["code"] as? String ?? event["code"] as? String ?? "incomplete_response"
                throw ExecError("OpenAI: \(code)")
            default: return nil
            }
        }

        private func serializedOutput() throws -> Data {
            guard items.count <= 256 else { throw ExecError("Response exceeded the output item limit.") }
            let output = items.keys.sorted().compactMap { items[$0] }
            let data = try JSONSerialization.data(withJSONObject: output)
            guard data.count <= 4 * 1024 * 1024 else { throw ExecError("Response output exceeded the size limit.") }
            return data
        }
    }
}
