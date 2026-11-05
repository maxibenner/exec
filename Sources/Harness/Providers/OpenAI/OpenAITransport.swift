import Foundation

// Parsing and network consumption stay off the UI actor. Only semantic events
// cross the boundary; the provider retains opaque response data for follow-ups.
enum OpenAITransport {
    enum Event: Sendable {
        case text(String)
        case completed(Data, tokens: Int?)
    }

    static func stream(_ request: URLRequest, session: URLSession = OpenAIHTTP.session) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    defer { bytes.task.cancel() }
                    try OpenAIHTTP.check(response)
                    var parser = SSEParser()
                    var decoder = ResponseDecoder()
                    var completed = false
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let data = try parser.push(byte), let event = try decoder.decode(data) else { continue }
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

    static func boundedResponse(_ request: URLRequest, session: URLSession) async throws -> Data {
        let task = Task.detached {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try OpenAIHTTP.check(response)
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 4 * 1024 * 1024 else { throw HarnessError("Compacted context exceeded the size limit.") }
                data.append(byte)
            }
            return data
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
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
                guard let delta = event["delta"] as? String else { throw HarnessError("Invalid text event.") }
                return .text(delta)
            case "response.output_item.done":
                guard let index = event["output_index"] as? Int, index >= 0, index < 256,
                      let item = event["item"] as? [String: Any] else {
                    throw HarnessError("Invalid completed output item.")
                }
                items[index] = item
                _ = try serializedOutput()
                return nil
            case "response.completed", "response.done":
                guard let response = event["response"] as? [String: Any],
                      response["status"] as? String == "completed" else {
                    throw HarnessError("Invalid completion event.")
                }
                if let rawOutput = response["output"] {
                    guard let output = rawOutput as? [[String: Any]], output.count <= 256 else {
                        throw HarnessError("Invalid completion output.")
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
                let usage = response["usage"] as? [String: Any]
                let input = usage?["input_tokens"] as? Int
                let output = usage?["output_tokens"] as? Int
                let tokens: Int?
                if let input, let output, (0...500_000_000).contains(input), (0...500_000_000).contains(output) {
                    tokens = input + output // Cached input is still part of the context window.
                } else { tokens = nil }
                return .completed(try serializedOutput(), tokens: tokens)
            case "response.failed", "response.incomplete", "error":
                let response = event["response"] as? [String: Any]
                let error = (response?["error"] as? [String: Any]) ?? (event["error"] as? [String: Any])
                let code = error?["code"] as? String ?? event["code"] as? String ?? "incomplete_response"
                throw HarnessError("OpenAI: \(code)")
            default: return nil
            }
        }

        private func serializedOutput() throws -> Data {
            guard items.count <= 256 else { throw HarnessError("Response exceeded the output item limit.") }
            let output = items.keys.sorted().compactMap { items[$0] }
            let data = try JSONSerialization.data(withJSONObject: output)
            guard data.count <= 4 * 1024 * 1024 else { throw HarnessError("Response output exceeded the size limit.") }
            return data
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
