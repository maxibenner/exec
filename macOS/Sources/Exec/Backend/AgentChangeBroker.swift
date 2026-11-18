import Foundation
#if canImport(ExecRemote)
import ExecRemote
#endif

/// A lease on the API's single read-only notification connection. Finishing one
/// lease never cancels another observer, and never sends an operation cancellation.
final class AgentChangeSubscription: Sendable {
    enum Signal: Sendable { case catchUp, unsupported }
    let stream: AsyncStream<Signal>
    private let continuation: AsyncStream<Signal>.Continuation
    init(stream: AsyncStream<Signal>, continuation: AsyncStream<Signal>.Continuation) {
        self.stream = stream; self.continuation = continuation
    }
    func close() { continuation.finish() }
    deinit { continuation.finish() }
}

actor AgentChangeBroker {
    enum Scope: Sendable { case catalog, conversation(UUID) }
    typealias Signal = AgentChangeSubscription.Signal
    private struct Observer {
        let scope: Scope
        let continuation: AsyncStream<Signal>.Continuation
    }
    private let transport: any AgentTransport
    private let sleep: @Sendable (Duration) async throws -> Void
    private var observers: [UUID: Observer] = [:]
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private var latest: RemoteChangeNotification?
    private var unsupported = false
    private var disconnected = false
    private var closed = false

    init(transport: any AgentTransport,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.transport = transport; self.sleep = sleep
    }

    func subscribe(_ scope: Scope) -> AgentChangeSubscription {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Signal>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let subscription = AgentChangeSubscription(stream: stream, continuation: continuation)
        guard !closed else { continuation.finish(); return subscription }
        continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        observers[id] = Observer(scope: scope, continuation: continuation)
        if unsupported { continuation.yield(.unsupported) }
        else if latest != nil || disconnected { continuation.yield(.catchUp) }
        if task == nil, !unsupported {
            let run = UUID(); runID = run
            task = Task { await self.run(run) }
        }
        return subscription
    }

    private func remove(_ id: UUID) {
        observers.removeValue(forKey: id)
        guard observers.isEmpty else { return }
        task?.cancel(); task = nil; runID = UUID()
        latest = nil; disconnected = false
    }

    func close() {
        closed = true
        task?.cancel(); task = nil; runID = UUID()
        for observer in observers.values { observer.continuation.finish() }
        observers.removeAll(); latest = nil
    }

    private func publish(_ notice: RemoteChangeNotification, initial: Bool) {
        for observer in observers.values {
            let changed: Bool
            switch observer.scope {
            case .catalog: changed = latest?.catalog != notice.catalog
            case .conversation(let id):
                let key = id.uuidString.lowercased()
                changed = latest?.conversations[key] != notice.conversations[key]
            }
            if initial || latest?.epoch != notice.epoch || changed { observer.continuation.yield(.catchUp) }
        }
        latest = notice
        disconnected = false
    }

    private func run(_ run: UUID) async {
        var delay = 250
        while !Task.isCancelled, run == runID {
            let started = ContinuousClock.now
            do {
                var initial = true
                for try await line in transport.events("GET", "/v1/changes", body: nil) {
                    try Task.checkCancellation()
                    guard run == runID else { return }
                    // The HTTP parser already ignores blank heartbeat lines. Also
                    // tolerate them in injected transports without decoding JSON.
                    if line.allSatisfy({ $0 == 10 || $0 == 13 || $0 == 32 || $0 == 9 }) { continue }
                    let notice = try JSONDecoder().decode(RemoteChangeNotification.self, from: line)
                    publish(notice, initial: initial)
                    initial = false
                }
            } catch {
                guard !Task.isCancelled, run == runID else { return }
                if let http = error as? AgentHTTPError, http.status == 404 || http.status == 405 {
                    unsupported = true
                    for observer in observers.values { observer.continuation.yield(.unsupported) }
                    task = nil
                    return
                }
            }
            guard !Task.isCancelled, run == runID else { return }
            // A disconnect is not evidence of an old server. Catch up read-only,
            // then reconnect; the new initial map always invalidates all scopes.
            disconnected = true
            for observer in observers.values { observer.continuation.yield(.catchUp) }
            if started.duration(to: .now) >= .seconds(30) { delay = 250 }
            do { try await sleep(.milliseconds(delay)) } catch { return }
            delay = min(delay * 2, 8_000)
        }
    }
}
