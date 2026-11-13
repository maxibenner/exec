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
        guard let encrypted = packet["ciphertext"].string.flatMap({ Data(base64Encoded: $0) }) else { throw RemoteFailure("Invalid encrypted response.") }
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

/// One ordered request at a time, no mutation retries. The v1 mobile UI polls
/// snapshots rather than retaining event history while iOS is suspended.
public actor RelayClient {
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var channel: SecureChannel?
    private var busy = false
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration, delegate: RelaySessionDelegate(), delegateQueue: nil)
    }
    public func disconnect() { socket?.cancel(with: .goingAway, reason: nil); socket = nil; channel = nil }
    public func connect(_ host: PairedHost) async throws {
        guard !busy else { throw RemoteFailure("A request is still in progress.") }
        busy = true; defer { busy = false }
        disconnect()
        try host.invitation.validate()
        guard let url = URL(string: host.invitation.relay.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/client/" + host.invitation.route) else { throw RemoteFailure("Invalid relay URL.") }
        let socket = session.webSocketTask(with: url); socket.maximumMessageSize = 1024 * 1024
        self.socket = socket; socket.resume()
        let timeout = Task { try await Task.sleep(for: .seconds(25)); socket.cancel(with: .goingAway, reason: nil) }
        defer { timeout.cancel() }
        do {
            let challenge = try await receive(socket)
            guard challenge["version"].number == 1, let nonce = challenge["challenge"].string else { throw RemoteFailure("Incompatible relay connection.") }
            var channel = try SecureChannel(host: host, challenge: nonce)
            let hello: RemoteJSON = .object(["name": .string(host.deviceName), "invitation": .optional(host.invitation.secret)])
            try await send(socket, channel.seal(hello, initial: true))
            let ready = try channel.open(await receive(socket))
            guard ready["ready"].bool else { throw RemoteFailure("Pairing was rejected.") }
            self.channel = channel
        } catch { disconnect(); throw RemoteFailure("Could not connect or authenticate. Check that the agent and relay are running; create a new invitation if this device is not paired.") }
    }
    public func request(_ method: String, _ path: String, body: RemoteJSON? = nil) async throws -> RemoteJSON {
        // Concurrent UI reads wait, but a disconnected command is never queued for replay.
        guard let expectedSocket = socket else { throw RemoteFailure("Connect to the agent first.") }
        while busy { try await Task.sleep(for: .milliseconds(20)) }
        guard socket === expectedSocket, let socket, var channel else { throw RemoteFailure("Connect to the agent first.") }
        busy = true; defer { busy = false }
        let timeout = Task { try await Task.sleep(for: .seconds(45)); socket.cancel(with: .goingAway, reason: nil) }
        defer { timeout.cancel() }
        do {
            let id = UUID().uuidString.lowercased()
            let request: RemoteJSON = .object(["id":.string(id), "method":.string(method), "path":.string(path), "body":body ?? .null])
            guard try JSONEncoder().encode(request).count <= 196_608 else { throw RemoteFailure("The request is too large.") }
            try await send(socket, channel.seal(request))
            var bytes = Data(); var status: Double = 0
            while true {
                let response = try channel.open(await receive(socket))
                guard response["id"].string == id, let chunk = response["body"].string.flatMap({ Data(base64Encoded: $0) }), bytes.count + chunk.count <= 32 * 1024 * 1024 else { throw RemoteFailure("Invalid remote response.") }
                bytes.append(chunk); status = response["status"].number ?? 500
                if response["done"].bool { break }
            }
            self.channel = channel
            let value = try JSONDecoder().decode(RemoteJSON.self, from: bytes)
            guard (200..<300).contains(status) else { throw APIRejection(message: value["error"].string ?? "Request rejected.") }
            return value
        } catch let rejection as APIRejection { throw RemoteFailure(rejection.message) }
        catch { disconnect(); throw RemoteFailure("Connection interrupted. The request may have taken effect. Reconnect to refresh; it was not retried.") }
    }
    private struct APIRejection: Error { let message: String }
    private func send(_ socket: URLSessionWebSocketTask, _ value: RemoteJSON) async throws {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try await withTaskCancellationHandler { try await socket.send(.string(text)) } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
    private func receive(_ socket: URLSessionWebSocketTask) async throws -> RemoteJSON {
        try await withTaskCancellationHandler {
            let message = try await socket.receive()
            guard case .string(let text) = message, text.utf8.count <= 1024 * 1024 else { throw RemoteFailure("Invalid relay frame.") }
            return try JSONDecoder().decode(RemoteJSON.self, from: Data(text.utf8))
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
}
