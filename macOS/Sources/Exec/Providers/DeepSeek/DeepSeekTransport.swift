import Foundation

enum DeepSeekTransport {
    struct Output: Sendable {
        let reasoning: String
        let calls: [ToolCall]
        let tokens: Int?
    }
    enum Event: Sendable {
        case text(String)
        case completed(Output)
    }

    static func stream(_ request: URLRequest, session: URLSession) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    try Task.checkCancellation()
                    let (bytes, response) = try await session.bytes(for: request)
                    defer { bytes.task.cancel() }
                    try DeepSeekHTTP.check(response)
                    var framing = SSEParser()
                    var decoder = Decoder()
                    var completed = false
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let data = try framing.push(byte) else { continue }
                        if let event = try decoder.decode(data) {
                            continuation.yield(event)
                            if case .completed = event { completed = true; break }
                        }
                    }
                    try Task.checkCancellation()
                    guard completed else { throw ExecError("DeepSeek's response ended before completion. No retry was made.") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct Decoder {
        private struct Call {
            var id = ""
            var name = ""
            var arguments = ""
        }
        private var calls: [Int: Call] = [:]
        private var reasoning = ""
        private var textBytes = 0
        private var hasText = false
        private var tokens: Int?
        private var finishReason: String?

        mutating func decode(_ data: Data) throws -> Event? {
            if data == Data("[DONE]".utf8) {
                guard let finishReason, ["stop", "tool_calls"].contains(finishReason) else {
                    throw ExecError("DeepSeek did not complete the response.")
                }
                var ids = Set<String>()
                let completeCalls = try calls.sorted { $0.key < $1.key }.map { _, call in
                    guard !call.id.isEmpty, !call.name.isEmpty, ids.insert(call.id).inserted,
                          let arguments = call.arguments.data(using: .utf8),
                          (try? JSONSerialization.jsonObject(with: arguments)) is [String: Any] else {
                        throw ExecError("DeepSeek returned an invalid tool call.")
                    }
                    return ToolCall(id: call.id, name: call.name, arguments: call.arguments)
                }
                guard (finishReason == "tool_calls") == !completeCalls.isEmpty else {
                    throw ExecError("DeepSeek returned inconsistent tool completion.")
                }
                guard hasText || !completeCalls.isEmpty else { throw ExecError("DeepSeek returned an empty response.") }
                return .completed(Output(reasoning: reasoning, calls: completeCalls, tokens: tokens))
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["error"] == nil,
                  let choices = json["choices"] as? [[String: Any]], choices.count <= 1 else {
                throw ExecError("DeepSeek returned an invalid stream event.")
            }
            if let usage = json["usage"] as? [String: Any], let total = usage["total_tokens"] as? Int,
               (0...1_000_000_000).contains(total) { tokens = total }
            guard let choice = choices.first else { return nil } // Terminal usage-only chunk.
            guard choice["index"] as? Int == 0, finishReason == nil else {
                throw ExecError("DeepSeek returned an unexpected response choice.")
            }
            let delta = choice["delta"] as? [String: Any] ?? [:]
            if let value = delta["reasoning_content"] as? String {
                reasoning += value
                guard reasoning.utf8.count <= 4 * 1024 * 1024 else { throw ExecError("DeepSeek reasoning exceeded the size limit.") }
            }
            if let fragments = delta["tool_calls"] as? [[String: Any]] {
                for fragment in fragments {
                    guard let index = fragment["index"] as? Int, (0..<16).contains(index),
                          fragment["type"] == nil || fragment["type"] as? String == "function" else {
                        throw ExecError("DeepSeek returned invalid or excessive tool calls.")
                    }
                    var call = calls[index] ?? Call()
                    if let id = fragment["id"] as? String { call.id += id }
                    if let function = fragment["function"] as? [String: Any] {
                        call.name += function["name"] as? String ?? ""
                        call.arguments += function["arguments"] as? String ?? ""
                    }
                    guard call.id.utf8.count <= 256, call.name.utf8.count <= 128,
                          call.arguments.utf8.count <= 32_768 else { throw ExecError("DeepSeek tool call exceeded the size limit.") }
                    calls[index] = call
                }
            }
            if let reason = choice["finish_reason"] as? String {
                guard ["stop", "tool_calls"].contains(reason) else {
                    throw ExecError(reason == "length"
                        ? "DeepSeek reached its output or context limit. The response is incomplete."
                        : "DeepSeek stopped before completing the response. No retry was made.")
                }
                finishReason = reason
            }
            if let text = delta["content"] as? String, !text.isEmpty {
                hasText = hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                textBytes += text.utf8.count
                guard textBytes <= 4 * 1024 * 1024 else { throw ExecError("DeepSeek response exceeded the size limit.") }
                return .text(text)
            }
            return nil
        }
    }
}
