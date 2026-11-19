#if DEBUG && targetEnvironment(simulator)
import Foundation
import ExecRemote

/// Transcript-only fake responses. Time advances the synthetic response on
/// ordinary store reads; no model, network, Keychain, or background producer.
@MainActor enum TranscriptUIFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--transcript-fixture") }
    private struct Turn {
        let text: String
        let started: Date
    }
    private static var turns: [String: Turn] = [:]

    static func request(_ method: String, _ path: String, body: RemoteJSON?) async throws -> RemoteJSON? {
        guard enabled, path.hasPrefix("/v1/conversations/") else { return nil }
        let parts = path.split(separator: "/")
        guard parts.count >= 4 else { return nil }
        let id = String(parts[2])
        if method == "POST", parts[3] == "turns" || parts[3] == "steer" {
            turns[id] = Turn(text: body?["text"].string ?? "Fixture question", started: Date())
            return .object(["operationID": .string("transcript-operation-\(id)")])
        }
        guard method == "GET", parts[3].hasPrefix("sync") else { return nil }
        if ProcessInfo.processInfo.arguments.contains("--transcript-follow"), turns[id] == nil {
            turns[id] = Turn(text: "Synthetic existing response", started: Date())
        }
        let tools = ProcessInfo.processInfo.arguments.contains("--transcript-tools")
        let messages = tools ? toolMessages : scrollMessages(id)
        let query = URLComponents(string: "https://fixture.invalid\(path)")?.queryItems ?? []
        let before = query.first { $0.name == "before" }?.value
        let after = query.first { $0.name == "after" }?.value
        let start: Int
        let end: Int
        let reset: Bool
        if let before, let index = messages.firstIndex(where: { $0["id"].string == before }) {
            if ProcessInfo.processInfo.arguments.contains("--transcript-paging") { try await Task.sleep(for: .seconds(4)) }
            start = max(0, index - 8); end = index; reset = false
        } else if let after, let index = messages.firstIndex(where: { $0["id"].string == after }) {
            start = index; end = messages.count; reset = false
        } else {
            start = tools ? 0 : max(0, messages.count - 12); end = messages.count; reset = true
        }
        let duration: TimeInterval = ProcessInfo.processInfo.arguments.contains("--transcript-follow") ? 30 : 20
        let active = tools || turns[id].map { Date().timeIntervalSince($0.started) < duration } == true
        var snapshot: [String: RemoteJSON] = [
            "id": .string(id), "metadata": .object(["title": .string("Session \(id.split(separator: "-").last ?? "")")]),
            "messages": .array(Array(messages[start..<end])),
            "operation": .object(["id": .string(turns[id] == nil ? "transcript-idle-\(id)" : "transcript-operation-\(id)"),
                                   "state": .string(active ? "running" : "completed")])
        ]
        if tools { snapshot["activeToolCallID"] = .string("active") }
        return .object(["snapshot": .object(snapshot), "offset": .number(Double(start)), "total": .number(Double(messages.count)),
                        "reset": .bool(reset), "prefix": messages.isEmpty ? .null : .string(String(repeating: "a", count: 64))])
    }
    private static func scrollMessages(_ id: String) -> [RemoteJSON] {
        var messages: [RemoteJSON] = (1...24).map { index in
            .object(["id": .string("history-\(index)"), "role": .string(index.isMultiple(of: 2) ? "assistant" : "user"),
                     "text": .string("\(id) reading marker \(index)\nSynthetic history for paging and manual reading."), "status": .string("completed")])
        }
        if let turn = turns[id] {
            let interval = ProcessInfo.processInfo.arguments.contains("--transcript-follow") ? 0.45 : 0.3
            let count = min(60, max(1, Int(Date().timeIntervalSince(turn.started) / interval) + 1))
            let text = (1...count).map { "Response paragraph \($0). This synthetic answer grows while the reader keeps a stable viewport." }.joined(separator: "\n\n")
            messages += [.object(["id": .string("submitted-user"), "role": .string("user"), "text": .string(turn.text)]),
                         .object(["id": .string("streaming-answer"), "role": .string("assistant"), "text": .string(text)])]
        }
        return messages
    }
    private static var toolMessages: [RemoteJSON] {
        let calls: [RemoteJSON] = ["first", "second", "active"].map { id in
            .object(["id": .string(id), "name": .string("shell"),
                     "arguments": .object(["command": .string("printf '\(id)'"), "description": .string("Print \(id)")])])
        }
        return [.object(["id": .string("tool-question"), "role": .string("user"), "text": .string("Check joined tools")]),
                .object(["id": .string("tool-calls"), "role": .string("assistant"), "calls": .array(calls)])]
            + ["first", "second"].map { id in
                .object(["id": .string("result-\(id)"), "role": .string("tool"), "callID": .string(id),
                         "outcome": .string("completed"), "text": .string("Isolated \(id) output")])
            }
    }
}
#endif
