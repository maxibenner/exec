import Foundation

/// Decode each bounded wire page directly into its native types. Historical
/// messages never pass through RemoteJSON/JSONEncoder/JSONDecoder again.
struct AgentSyncPage: Decodable, Sendable {
    let snapshot: AgentSnapshot
    let offset: Int
    let total: Int
    let reset: Bool
    let prefix: String?

    func validate() throws {
        guard offset >= 0, total >= offset, snapshot.messages.count <= total - offset,
              (total == 0 && prefix == nil) || (total > 0 && prefix?.utf8.count == 64) else {
            throw ExecError("Invalid conversation page.")
        }
    }
}

struct AgentTranscriptState: Sendable {
    var snapshot: AgentSnapshot
    let offset: Int
    let total: Int
    let prefix: String?

    static func initial(_ page: AgentSyncPage) throws -> Self {
        try page.validate()
        guard page.reset, page.offset + page.snapshot.messages.count == page.total else {
            throw ExecError("Invalid conversation page.")
        }
        return Self(snapshot: page.snapshot, offset: page.offset, total: page.total, prefix: page.prefix)
    }

    func refreshed(_ page: AgentSyncPage) throws -> (Self, changed: Bool) {
        try page.validate()
        guard page.snapshot.id == snapshot.id else { throw ExecError("The backend returned a different conversation.") }
        if page.reset { return (try Self.initial(page), true) }
        guard let last = snapshot.messages.last, page.snapshot.messages.first?.id == last.id,
              page.offset == offset + snapshot.messages.count - 1,
              page.offset + page.snapshot.messages.count == page.total else {
            throw ExecError("Conversation updates are out of order. Refresh the conversation.")
        }
        // Compare only the bounded overlap and message-free header before copying
        // history or projecting UI rows. Prefix proofs validate the retained prefix.
        var header = snapshot; header.messages = []
        var incoming = page.snapshot; incoming.messages = []
        let changed = header != incoming || page.snapshot.messages.count != 1 || page.snapshot.messages[0] != last
        if !changed {
            return (Self(snapshot: snapshot, offset: offset, total: page.total, prefix: page.prefix), false)
        }
        incoming.messages = snapshot.messages
        incoming.messages.removeLast()
        incoming.messages.append(contentsOf: page.snapshot.messages)
        return (Self(snapshot: incoming, offset: offset, total: page.total, prefix: page.prefix), true)
    }

    func prepending(_ page: AgentSyncPage) throws -> Self {
        try page.validate()
        guard !page.reset, page.snapshot.id == snapshot.id,
              page.offset + page.snapshot.messages.count == offset, page.total >= total,
              !page.snapshot.messages.isEmpty else {
            throw ExecError("Conversation history changed. Refresh the conversation.")
        }
        var combined = snapshot
        combined.messages = page.snapshot.messages + snapshot.messages
        // Older reads may observe a later tail. Keep the ORIGINAL tail proof and
        // total, so the next refresh detects that change instead of blessing it.
        return Self(snapshot: combined, offset: page.offset, total: total, prefix: prefix)
    }

    func refreshPath(_ base: String) -> String {
        guard let last = snapshot.messages.last, let prefix else { return base }
        return "\(base)?after=\(last.id.uuidString.lowercased())&prefix=\(prefix)"
    }
    func earlierPath(_ base: String) -> String? {
        guard offset > 0, let first = snapshot.messages.first else { return nil }
        return "\(base)?before=\(first.id.uuidString.lowercased())"
    }
}

/// One consumer; hidden resident sessions keep their lease and stay current.
actor AgentTranscriptReader {
    private let transport: any AgentTransport
    private let changes: AgentChangeBroker
    private let id: UUID
    private let path: String
    private var state: AgentTranscriptState?
    private var subscription: AgentChangeSubscription?
    private var legacyPolling = false
    private let sleep: @Sendable (Duration) async throws -> Void

    init(transport: any AgentTransport, id: UUID, path: String, changes: AgentChangeBroker? = nil,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.transport = transport; self.id = id; self.path = path
        self.changes = changes ?? AgentChangeBroker(transport: transport)
        self.sleep = sleep
    }

    /// Initial subscription is established before the authoritative read. Changes
    /// received during ANY page read remain buffered for the next catchup.
    private func subscribe() async throws -> Bool {
        try Task.checkCancellation()
        guard subscription == nil else { return false }
        let subscription = await changes.subscribe(.conversation(id))
        self.subscription = subscription
        try await notification()
        return true
    }
    private func notification() async throws {
        guard let subscription else { throw CancellationError() }
        let signal = await Self.receive(subscription.stream)
        try Task.checkCancellation()
        guard let signal else { throw CancellationError() }
        if case .unsupported = signal { legacyPolling = true }
    }
    // AsyncStream's buffer belongs to the stream, not the iterator. Keep each
    // sequential receive local to the nonisolated executor (also works on macOS
    // 14, without the macOS 15-only next(isolation:) overload).
    private nonisolated static func receive(_ stream: AsyncStream<AgentChangeSubscription.Signal>) async -> AgentChangeSubscription.Signal? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
    func close() {
        subscription?.close(); subscription = nil
    }

    func read() async throws -> AgentSnapshot {
        do {
            _ = try await subscribe()
            return try await fetchSnapshot().snapshot
        } catch {
            if Task.isCancelled { close() }
            throw error
        }
    }

    func next() async throws -> AgentSnapshot {
        do {
            var catchUp = try await subscribe() || state == nil
            while true {
                if !catchUp {
                    if legacyPolling {
                        try await sleep(state?.snapshot.operation?.active == true ? .milliseconds(200) : .seconds(2))
                    } else { try await notification() }
                }
                let result = try await fetchSnapshot()
                if result.changed { return result.snapshot }
                catchUp = false
            }
        } catch {
            if Task.isCancelled { close() }
            throw error
        }
    }

    private func fetchSnapshot() async throws -> (snapshot: AgentSnapshot, changed: Bool) {
        let page = try await fetch(state?.refreshPath(path) ?? path)
        guard page.snapshot.id == id else { throw ExecError("The backend returned a different conversation.") }
        var (next, changed) = try state.map { try $0.refreshed(page) } ?? (AgentTranscriptState.initial(page), true)
        while let earlier = next.earlierPath(path) { next = try next.prepending(await fetch(earlier)) }
        // Reset/empty snapshots can also be unchanged. This cold-path comparison
        // is never used for the warm bounded suffix case.
        if page.reset { changed = next.snapshot != state?.snapshot }
        try Task.checkCancellation()
        state = next
        return (next.snapshot, changed)
    }
    private func fetch(_ path: String) async throws -> AgentSyncPage {
        let data = try await transport.request("GET", path, body: nil)
        try Task.checkCancellation()
        return try JSONDecoder().decode(AgentSyncPage.self, from: data)
    }
}
