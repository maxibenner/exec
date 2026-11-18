import Foundation
import CryptoKit

public struct PairingInvitation: Codable, Sendable {
    public let version: Int
    public let relay: String
    public let route: String
    public let hostKey: String
    public var secret: String?
    public let expires: Double
    public let localDevelopment: Bool

    public static func parse(_ text: String) throws -> Self {
        guard text.utf8.count < 4096, let data = text.data(using: .utf8) else { throw RemoteFailure("Invalid pairing invitation.") }
        let invitation = try JSONDecoder().decode(Self.self, from: data)
        try invitation.validate()
        guard invitation.expires > Date().timeIntervalSince1970, invitation.secret?.count == 64 else { throw RemoteFailure("This invitation has expired. Create a new QR code on the Mac.") }
        return invitation
    }
    public func validate() throws {
        guard version == 1, route.count == 64, route.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let key = Data(base64Encoded: hostKey), key.count == 32,
              let url = URLComponents(string: relay), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { throw RemoteFailure("Invalid pairing invitation.") }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        let privateIPv4 = octets.count == 4 && (octets[0] == 127 || octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1])))
        let privateHost = host == "localhost" || host == "[::1]" || host == "::1" || privateIPv4
        guard url.scheme == "wss" || (localDevelopment && url.scheme == "ws" && privateHost) else { throw RemoteFailure("Production relays require wss://. Local development is limited to private networks.") }
    }
}
public struct PairedHost: Codable, Sendable {
    public var invitation: PairingInvitation
    public let devicePrivateKey: Data
    public let deviceName: String
    public init(invitation: PairingInvitation, deviceName: String) {
        self.invitation = invitation
        self.devicePrivateKey = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        self.deviceName = deviceName
    }
}

/// RFC 9180 authenticated HPKE; sequence counters are owned by CryptoKit.
/// A fresh server challenge binds the contexts to one live connection.
struct SecureChannel {
    private var sender: HPKE.Sender
    private var recipient: HPKE.Recipient?
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let hostKey: Curve25519.KeyAgreement.PublicKey
    private let challenge: String
    private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    init(host: PairedHost, challenge: String) throws {
        guard challenge.count == 64, challenge.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let hostBytes = Data(base64Encoded: host.invitation.hostKey) else { throw RemoteFailure("Invalid host handshake.") }
        self.challenge = challenge
        privateKey = try .init(rawRepresentation: host.devicePrivateKey)
        hostKey = try .init(rawRepresentation: hostBytes)
        sender = try HPKE.Sender(recipientKey: hostKey, ciphersuite: Self.suite,
            info: Data("exec-remote-v1:client:\(challenge)".utf8), authenticatedBy: privateKey)
    }
    mutating func seal(_ value: RemoteJSON, initial: Bool = false) throws -> RemoteJSON {
        var packet: [String: RemoteJSON] = ["ciphertext": .string(try sender.seal(JSONEncoder().encode(value)).base64EncodedString())]
        if initial {
            packet["encapsulatedKey"] = .string(sender.encapsulatedKey.base64EncodedString())
            packet["publicKey"] = .string(privateKey.publicKey.rawRepresentation.base64EncodedString())
        }
        return .object(packet)
    }
    mutating func open(_ packet: RemoteJSON) throws -> RemoteJSON {
        guard case .object(let fields) = packet,
              Set(fields.keys).isSubset(of: Set(["ciphertext", "encapsulatedKey", "publicKey"])),
              packet["publicKey"] == .null,
              let encrypted = packet["ciphertext"].string.flatMap({ Data(base64Encoded: $0) }) else { throw RemoteFailure("Invalid encrypted response.") }
        if recipient == nil {
            guard let enc = packet["encapsulatedKey"].string.flatMap({ Data(base64Encoded: $0) }) else { throw RemoteFailure("Missing host identity proof.") }
            recipient = try HPKE.Recipient(privateKey: privateKey, ciphersuite: Self.suite,
                info: Data("exec-remote-v1:host:\(challenge)".utf8), encapsulatedKey: enc, authenticatedBy: hostKey)
        } else if packet["encapsulatedKey"] != .null { throw RemoteFailure("Unexpected handshake.") }
        return try JSONDecoder().decode(RemoteJSON.self, from: recipient!.open(encrypted))
    }
}

private final class RelaySessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

// Internal transport seam: tests exercise real HPKE without network traffic.
protocol RelaySocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

private final class WebSocketTransport: RelaySocket, Sendable {
    let task: URLSessionWebSocketTask
    init(session: URLSession, url: URL) {
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 1024 * 1024
        task.resume()
    }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func receive() async throws -> String {
        guard case .string(let text) = try await task.receive() else { throw RemoteFailure("Invalid relay frame.") }
        return text
    }
    func close() { task.cancel(with: .goingAway, reason: nil) }
}

// Cancellation must become visible before its actor cleanup task can run.
// The locked dispatch claim is the boundary after which commands drain, never retry.
private final class RelayRequestCancellation: @unchecked Sendable {
    private enum State { case queued, cancelled, dispatched }
    private let lock = NSLock()
    private var state = State.queued
    func cancel() { lock.withLock { if state == .queued { state = .cancelled } } }
    func claimDispatch() -> Bool {
        lock.withLock {
            guard state == .queued else { return false }
            state = .dispatched
            return true
        }
    }
}

/// One socket, one ordered receive pump, and sequential requests. Nothing is retried.
public actor RelayClient {
    private let makeSocket: @Sendable (URL) -> any RelaySocket
    private let beforeDispatch: @Sendable () -> Void
    private var socket: (any RelaySocket)?
    private var channel: SecureChannel?
    private var generation = UUID()
    private var connecting = false
    private var pump: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private let livenessTimeout: Duration
    private var lastAuthenticatedTraffic = ContinuousClock.now
    private var supportsChanges = false

    private struct Pending {
        let id: String
        let value: RemoteJSON
        var continuation: CheckedContinuation<RemoteJSON, Error>?
        let observationID: UUID?
        let cancellation: RelayRequestCancellation
        var bytes = Data()
        var status: Int?
    }
    private var active: Pending?
    private var queue: [Pending] = [] // bounded, FIFO; never carried across connections
    var queuedRequestCount: Int { queue.count } // internal deterministic test synchronization
    private struct Observation {
        let id: UUID
        let continuation: AsyncThrowingStream<RemoteChangeNotification, Error>.Continuation
        var ready = false
    }
    private var observation: Observation?
    // Once opted in, keep opening/discarding notices even after a consumer cancels.
    private var optedIn = false

    public init() {
        livenessTimeout = .seconds(70)
        beforeDispatch = {}
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration, delegate: RelaySessionDelegate(), delegateQueue: nil)
        makeSocket = { WebSocketTransport(session: session, url: $0) }
    }
    init(livenessTimeout: Duration = .seconds(70), beforeDispatch: @escaping @Sendable () -> Void = {}, makeSocket: @escaping @Sendable (URL) -> any RelaySocket) {
        precondition(livenessTimeout > .zero)
        self.livenessTimeout = livenessTimeout
        self.beforeDispatch = beforeDispatch
        self.makeSocket = makeSocket
    }
    deinit {
        socket?.close(); pump?.cancel(); timeout?.cancel(); watchdog?.cancel()
        observation?.continuation.finish()
    }

    public var isConnected: Bool { socket != nil && channel != nil }
    public func disconnect() { endConnection(RemoteFailure("Disconnected. Pending requests were not retried.")) }

    private func endConnection(_ error: any Error) {
        generation = UUID()
        socket?.close(); socket = nil; channel = nil; connecting = false
        pump?.cancel(); pump = nil; timeout?.cancel(); timeout = nil
        watchdog?.cancel(); watchdog = nil; supportsChanges = false
        active?.continuation?.resume(throwing: error); active = nil
        let waiting = queue; queue.removeAll()
        for request in waiting { request.continuation?.resume(throwing: error) }
        observation?.continuation.finish(throwing: error); observation = nil; optedIn = false
    }
    private func fail(_ error: any Error, generation expected: UUID) {
        guard generation == expected else { return }
        endConnection(error)
    }
    private func expireHandshake(generation expected: UUID) {
        guard connecting else { return }
        fail(Self.interrupted, generation: expected)
    }
    private func expireRequest(_ id: String, generation expected: UUID) {
        guard active?.id == id else { return }
        fail(Self.interrupted, generation: expected)
    }
    // Only subscribed connections promise idle heartbeats (old hosts do not).
    // One timer per generation, not one Task per token. Request deadlines continue
    // to govern active commands, even if they began near the idle deadline.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let expected = generation
        watchdog = Task { [weak self] in
            while let delay = await self?.livenessDelay(generation: expected) {
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }
    private func livenessDelay(generation expected: UUID) -> Duration? {
        guard generation == expected, optedIn else { return nil }
        if active != nil { return livenessTimeout }
        let remaining = livenessTimeout - lastAuthenticatedTraffic.duration(to: .now)
        guard remaining > .zero else {
            fail(Self.interrupted, generation: expected)
            return nil
        }
        return remaining
    }
    private static var interrupted: RemoteFailure {
        RemoteFailure("Connection interrupted. The request may have taken effect. It was not retried.")
    }

    public func connect(_ host: PairedHost) async throws {
        try Task.checkCancellation()
        guard !connecting, active == nil else { throw RemoteFailure("A request is still in progress.") }
        disconnect()
        try host.invitation.validate()
        guard let url = URL(string: host.invitation.relay.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/client/" + host.invitation.route) else { throw RemoteFailure("Invalid relay URL.") }
        let socket = makeSocket(url), expected = generation
        self.socket = socket; connecting = true
        let deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            await self?.expireHandshake(generation: expected)
        }
        defer { deadline.cancel() }
        do {
            try await withTaskCancellationHandler {
                // The handshake owns receives until the pump starts; never two readers.
                let challenge = try await Self.receive(socket)
                guard generation == expected else { throw CancellationError() }
                guard challenge["version"].number == 1, let nonce = challenge["challenge"].string else { throw RemoteFailure("Incompatible relay connection.") }
                var channel = try SecureChannel(host: host, challenge: nonce)
                let hello: RemoteJSON = .object(["name": .string(host.deviceName), "invitation": .optional(host.invitation.secret)])
                try await socket.send(Self.text(channel.seal(hello, initial: true)))
                guard generation == expected else { throw CancellationError() }
                let ready = try channel.open(await Self.receive(socket))
                try Task.checkCancellation()
                guard generation == expected else { throw CancellationError() }
                guard case .object(let fields) = ready, fields["ready"] == .bool(true) else { throw RemoteFailure("Pairing was rejected.") }
                // Authenticated opt-in only. Missing means an old host; never probe
                // its allowlist (which returns 403 before route lookup). Ignore new
                // unrelated fields but reject malformed known capabilities.
                if let capability = fields["changeNotifications"] {
                    guard case .bool(let enabled) = capability else { throw Self.interrupted }
                    supportsChanges = enabled
                }
                self.channel = channel; connecting = false
                pump = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let packet = try await Self.receive(socket)
                            guard let self else { return }
                            guard try await self.accept(packet, generation: expected) else { return }
                        }
                    } catch { await self?.fail(Self.interrupted, generation: expected) }
                }
            } onCancel: {
                socket.close()
                Task { await self.fail(CancellationError(), generation: expected) }
            }
        } catch {
            fail(Self.interrupted, generation: expected)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw RemoteFailure("Could not connect or authenticate. Check that the agent and relay are running; create a new invitation if this device is not paired.")
        }
    }

    public func request(_ method: String, _ path: String, body: RemoteJSON? = nil) async throws -> RemoteJSON {
        do { return try await perform(method, path, body: body) }
        catch let rejection as APIRejection { throw RemoteFailure(rejection.message) }
    }

    /// Opt in only when authenticated ready advertises support; otherwise no probe.
    /// An explicit 404/405 also means unsupported, but a generic 403 remains an error.
    /// One consumer per client. Await stopChanges() after cancelling the old owner
    /// before replacing it. Neither operation cancels an accepted API command.
    public func changes() async throws -> AsyncThrowingStream<RemoteChangeNotification, Error>? {
        try Task.checkCancellation()
        guard isConnected else { throw RemoteFailure("Connect to the agent first.") }
        guard supportsChanges else { return nil }
        guard observation == nil else { throw RemoteFailure("Changes are already being observed.") }
        let id = UUID()
        let (stream, continuation) = AsyncThrowingStream<RemoteChangeNotification, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observation = Observation(id: id, continuation: continuation)
        continuation.onTermination = { [weak self] _ in Task { await self?.endObservation(id) } }
        do {
            _ = try await perform("GET", "/v1/changes/subscribe", observationID: id)
            try Task.checkCancellation()
            return stream
        } catch {
            endObservation(id)
            if Task.isCancelled { throw CancellationError() }
            if let rejection = error as? APIRejection {
                if rejection.status == 404 || rejection.status == 405 { return nil }
                throw RemoteFailure(rejection.message)
            }
            throw error
        }
    }
    /// Ownership teardown boundary; does not close the socket or stop draining notices.
    public func stopChanges() {
        if let id = observation?.id { endObservation(id) }
    }
    private func endObservation(_ id: UUID) {
        guard observation?.id == id else { return }
        let continuation = observation?.continuation
        observation = nil
        continuation?.finish()
    }

    private func perform(_ method: String, _ path: String, body: RemoteJSON? = nil, observationID: UUID? = nil) async throws -> RemoteJSON {
        try Task.checkCancellation()
        guard isConnected else { throw RemoteFailure("Connect to the agent first.") }
        guard queue.count < 64 else { throw RemoteFailure("Too many pending requests.") }
        let id = UUID().uuidString.lowercased(), expected = generation
        let value: RemoteJSON = .object(["id": .string(id), "method": .string(method), "path": .string(path), "body": body ?? .null])
        guard try JSONEncoder().encode(value).count <= 196_608 else { throw RemoteFailure("The request is too large.") }
        let cancellation = RelayRequestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.append(Pending(id: id, value: value, continuation: continuation, observationID: observationID, cancellation: cancellation))
                startNext()
            }
        } onCancel: {
            cancellation.cancel() // synchronous, even while accept/startNext owns the actor
            Task { await self.cancelRequest(id, generation: expected) }
        }
    }
    private func cancelRequest(_ id: String, generation expected: UUID) {
        guard generation == expected else { return }
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).continuation?.resume(throwing: CancellationError())
        } else if active?.id == id {
            // Detach the caller, but drain the accepted reply and advance HPKE.
            let continuation = active?.continuation
            active?.continuation = nil
            continuation?.resume(throwing: CancellationError())
        }
    }
    private func startNext() {
        guard active == nil, let socket else { return }
        while !queue.isEmpty {
            beforeDispatch() // synchronous race-test seam; no suspension before sealing
            let candidate = queue.removeFirst()
            guard candidate.cancellation.claimDispatch() else {
                candidate.continuation?.resume(throwing: CancellationError())
                continue
            }
            active = candidate
            break
        }
        guard active != nil else { return }
        let expected = generation
        do {
            // Commit the sender context BEFORE suspension. Never copy it across await.
            let packet = try channel!.seal(active!.value)
            let text = try Self.text(packet), id = active!.id
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
                await self?.expireRequest(id, generation: expected)
            }
            Task { [weak self] in
                guard await self?.generation == expected else { return }
                do { try await socket.send(text) }
                catch { await self?.fail(Self.interrupted, generation: expected) }
            }
        } catch { fail(Self.interrupted, generation: expected) }
    }

    private struct APIRejection: Error { let status: Int; let message: String }
    private struct Reply: Decodable {
        let id: String
        let status: Int
        let body: String
        let done: Bool
    }
    /// Runs on the actor, without suspension: every encrypted frame advances the same
    /// recipient context, including notices, API rejections and abandoned requests.
    private func accept(_ packet: RemoteJSON, generation expected: UUID) throws -> Bool {
        guard generation == expected, channel != nil else { return false }
        let value = try channel!.open(packet)
        lastAuthenticatedTraffic = .now
        guard case .object(let fields) = value else { throw Self.interrupted }
        if let notification = fields["notification"] {
            guard optedIn, fields.count == 1 else { throw Self.interrupted }
            let change = try notification.decoded(RemoteChangeNotification.self)
            if observation?.ready == true { observation?.continuation.yield(change) }
            return true
        }
        guard Set(fields.keys) == Set(["id", "status", "body", "done"]), active != nil else { throw Self.interrupted }
        let reply = try value.decoded(Reply.self)
        guard UUID(uuidString: reply.id) != nil, reply.id == active!.id,
              (100...599).contains(reply.status), active!.status == nil || active!.status == reply.status,
              let chunk = Data(base64Encoded: reply.body), chunk.count <= 48 * 1024,
              reply.done || !chunk.isEmpty, active!.bytes.count + chunk.count <= 32 * 1024 * 1024 else { throw Self.interrupted }
        active!.bytes.append(chunk); active!.status = reply.status
        guard reply.done else { return true }
        let completed = active!
        // Decode API errors leniently: old 404/405 responses can have empty/non-JSON bodies.
        // Successful malformed responses are protocol failures, not capability fallback.
        let result: Result<RemoteJSON, Error>
        if (200..<300).contains(reply.status) {
            let body = try JSONDecoder().decode(RemoteJSON.self, from: completed.bytes)
            if let id = completed.observationID {
                let initial = try body.decoded(RemoteChangeNotification.self)
                optedIn = true
                startWatchdog()
                if observation?.id == id {
                    observation?.ready = true
                    observation?.continuation.yield(initial)
                }
            }
            result = .success(body)
        } else {
            let body = try? JSONDecoder().decode(RemoteJSON.self, from: completed.bytes)
            result = .failure(APIRejection(status: reply.status, message: body?["error"].string ?? "Request rejected."))
        }
        timeout?.cancel(); timeout = nil; active = nil
        completed.continuation?.resume(with: result)
        startNext()
        return true
    }
    private static func text(_ value: RemoteJSON) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    private static func receive(_ socket: any RelaySocket) async throws -> RemoteJSON {
        let text = try await socket.receive()
        guard text.utf8.count <= 1024 * 1024 else { throw RemoteFailure("Invalid relay frame.") }
        return try JSONDecoder().decode(RemoteJSON.self, from: Data(text.utf8))
    }
}
