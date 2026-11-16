import Foundation

#if canImport(ExecRemote)
import ExecRemote
#endif

/// One consumer, no queued history: reuse the same cursor/merge contract as iOS.
/// macOS backfills older pages before publishing so existing transcript navigation
/// and tool-call/result pairing keep the complete conversation available.
actor AgentTranscriptReader {
    private let transport: any AgentTransport
    private let id: UUID
    private let path: String
    private var state: RemoteTranscriptSync?

    init(transport: any AgentTransport, id: UUID, path: String) {
        self.transport = transport; self.id = id; self.path = path
    }

    func read() async throws -> AgentSnapshot {
        let page = try await fetch(state?.refreshPath(path) ?? path)
        var next = try state.map { try $0.refreshed(page) } ?? RemoteTranscriptSync.initial(page)
        while let earlier = next.earlierPath(path) {
            next = try next.prepending(await fetch(earlier))
        }
        let snapshot = try next.snapshot.decoded(AgentSnapshot.self)
        guard snapshot.id == id else { throw ExecError("The backend returned a different conversation.") }
        try Task.checkCancellation()
        state = next
        return snapshot
    }

    func next() async throws -> AgentSnapshot {
        while true {
            let previous = state?.snapshot
            if let previous {
                let active = ["running", "awaiting_approval", "cancelling"].contains(previous["operation"]["state"].string ?? "")
                try await Task.sleep(for: active ? .milliseconds(200) : .seconds(2))
            }
            let snapshot = try await read()
            // Avoid redundant UI reconciliation when neither content nor state changed.
            if state?.snapshot != previous { return snapshot }
        }
    }

    private func fetch(_ path: String) async throws -> AgentJSON {
        let data = try await transport.request("GET", path, body: nil)
        try Task.checkCancellation()
        return try JSONDecoder().decode(AgentJSON.self, from: data)
    }
}
