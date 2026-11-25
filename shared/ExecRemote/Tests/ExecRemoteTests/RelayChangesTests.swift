import XCTest
import CryptoKit
@testable import ExecRemote

// In-memory websocket + authenticated HPKE peer. No ports, providers or credentials.
private final class FramePipe: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String] = []
    private var reader: CheckedContinuation<String, Error>?
    private var closed = false
    private var simultaneousReaders = false
    let delayClose: Bool
    init(delayClose: Bool = false) { self.delayClose = delayClose }
    var hadConcurrentReads: Bool { lock.withLock { simultaneousReaders } }
    func push(_ text: String) {
        lock.withLock {
            if let reader { self.reader = nil; reader.resume(returning: text) }
            else { frames.append(text) }
        }
    }
    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if !frames.isEmpty { continuation.resume(returning: frames.removeFirst()) }
                else if closed { continuation.resume(throwing: RemoteFailure("Fixture closed")) }
                else if reader != nil {
                    simultaneousReaders = true
                    continuation.resume(throwing: RemoteFailure("Concurrent websocket receive"))
                } else { reader = continuation }
            }
        }
    }
    func close(force: Bool = false) {
        guard force || !delayClose else { return }
        lock.withLock {
            closed = true
            reader?.resume(throwing: RemoteFailure("Fixture closed")); reader = nil
        }
    }
}
private final class FakeSocket: RelaySocket, Sendable {
    let host: FakeHost
    init(_ host: FakeHost) { self.host = host }
    func send(_ text: String) async throws { try await host.receive(text) }
    func receive() async throws -> String { try await host.pipe.receive() }
    func close() { host.pipe.close() }
}
private final class SocketFactory: @unchecked Sendable {
    let sockets: [FakeSocket]
    private let lock = NSLock()
    private var index = 0
    init(_ hosts: [FakeHost]) { sockets = hosts.map(FakeSocket.init) }
    var count: Int { lock.withLock { index } }
    func make(_ url: URL) -> any RelaySocket {
        lock.withLock { defer { index += 1 }; return sockets[index] }
    }
}
private actor FakeHost {
    nonisolated let pipe: FramePipe
    nonisolated let paired: PairedHost
    nonisolated let challengeFrame: String
    private(set) var readyFrame: String?
    private(set) var initialClientKey: String?
    private let key: Curve25519.KeyAgreement.PrivateKey
    private let challenge = String(repeating: "c", count: 64)
    private let readyFields: [String: RemoteJSON]
    private var sender: HPKE.Sender?
    private var recipient: HPKE.Recipient?
    private var pending: [RemoteJSON] = []
    private var waiter: CheckedContinuation<RemoteJSON, Never>?
    private var holdNextSend = false
    private var heldSend: CheckedContinuation<Void, Error>?
    private(set) var commands: [RemoteJSON] = []
    init(delayClose: Bool = false, readyFields: [String: RemoteJSON] = ["changeNotifications": .bool(true)]) throws {
        self.readyFields = readyFields
        key = Curve25519.KeyAgreement.PrivateKey()
        pipe = FramePipe(delayClose: delayClose)
        paired = PairedHost(invitation: PairingInvitation(version: 1, relay: "wss://fixture.invalid", route: String(repeating: "a", count: 64), hostKey: key.publicKey.rawRepresentation.base64EncodedString(), secret: nil, expires: 0, localDevelopment: false), deviceName: "In-memory fixture")
        challengeFrame = String(decoding: try JSONEncoder().encode(RemoteJSON.object(["version": .number(2), "challenge": .string(challenge)])), as: UTF8.self)
        pipe.push(challengeFrame)
    }
    func receive(_ text: String) async throws {
        let packet = try JSONDecoder().decode(RemoteJSON.self, from: Data(text.utf8))
        if recipient == nil {
            let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(base64Encoded: packet["publicKey"].string!)!)
            let clientKey = packet["encapsulatedKey"].string!
            initialClientKey = clientKey
            recipient = try HPKE.Recipient(privateKey: key, ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: Data("exec-remote-v2:client:\(challenge)".utf8), encapsulatedKey: Data(base64Encoded: clientKey)!, authenticatedBy: peer)
            _ = try recipient!.open(Data(base64Encoded: packet["ciphertext"].string!)!)
            sender = try HPKE.Sender(recipientKey: peer, ciphersuite: .Curve25519_SHA256_ChachaPoly,
                info: Data("exec-remote-v2:host:\(challenge):\(clientKey)".utf8), authenticatedBy: key)
            var ready = readyFields
            ready["ready"] = .bool(true); ready["deviceID"] = .string(UUID().uuidString)
            if ready["version"] == nil { ready["version"] = .number(2) }
            try frame(.object(ready), initial: true)
        } else {
            let plaintext = try recipient!.open(Data(base64Encoded: packet["ciphertext"].string!)!)
            let command = try JSONDecoder().decode(RemoteJSON.self, from: plaintext)
            commands.append(command)
            if let waiter { self.waiter = nil; waiter.resume(returning: command) }
            else { pending.append(command) }
            if holdNextSend {
                holdNextSend = false
                try await withCheckedThrowingContinuation { heldSend = $0 }
            }
        }
    }
    func holdNextCommandSend() { holdNextSend = true }
    func failHeldSend() {
        heldSend?.resume(throwing: RemoteFailure("Fixture lost send acknowledgement after acceptance"))
        heldSend = nil
    }
    func nextCommand() async -> RemoteJSON {
        if !pending.isEmpty { return pending.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }
    func frame(_ value: RemoteJSON, initial: Bool = false) throws {
        let ciphertext = try sender!.seal(JSONEncoder().encode(value))
        var packet: [String: RemoteJSON] = ["ciphertext": .string(ciphertext.base64EncodedString())]
        if initial { packet["encapsulatedKey"] = .string(sender!.encapsulatedKey.base64EncodedString()) }
        let text = String(decoding: try JSONEncoder().encode(RemoteJSON.object(packet)), as: UTF8.self)
        if initial { readyFrame = text }
        pipe.push(text)
    }
    func reply(_ command: RemoteJSON, _ value: RemoteJSON = .object(["ok": .bool(true)]), status: Int = 200) throws {
        try chunk(command, JSONEncoder().encode(value), status: status)
    }
    func chunk(_ command: RemoteJSON, _ bytes: Data, status: Int = 200, done: Bool = true) throws {
        try frame(.object(["id": command["id"], "status": .number(Double(status)), "body": .string(bytes.base64EncodedString()), "done": .bool(done)]))
    }
    static func change(_ revision: String) -> RemoteJSON {
        .object(["epoch": .string("epoch"), "catalog": .string(revision), "conversations": .object(["session": .string(revision)])])
    }
    func notice(_ revision: String) throws { try frame(.object(["notification": Self.change(revision)])) }
}

// Malicious relay: records frames and replays them without contacting the host.
private final class RecordedHandshakeSocket: RelaySocket, @unchecked Sendable {
    private let pipe = FramePipe()
    private let lock = NSLock()
    private var sent: [String] = []
    var sentFrames: [String] { lock.withLock { sent } }
    init(_ frames: [String]) { for frame in frames { pipe.push(frame) } }
    func send(_ text: String) async throws { lock.withLock { sent.append(text) } }
    func receive() async throws -> String { try await pipe.receive() }
    func close() { pipe.close() }
}

private final class DispatchHook: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    func set(_ action: @escaping @Sendable () -> Void) { lock.withLock { self.action = action } }
    func run() {
        let action = lock.withLock { let action = self.action; self.action = nil; return action }
        action?()
    }
}

final class RelayChangesTests: XCTestCase, @unchecked Sendable {
    private func connected(livenessTimeout: Duration = .seconds(70), beforeDispatch: @escaping @Sendable () -> Void = {}) async throws -> (RelayClient, FakeHost) {
        let host = try FakeHost(), socket = FakeSocket(host)
        let client = RelayClient(livenessTimeout: livenessTimeout, beforeDispatch: beforeDispatch, makeSocket: { _ in socket })
        try await client.connect(host.paired)
        return (client, host)
    }
    private func subscribe(_ client: RelayClient, _ host: FakeHost, status: Int = 200) async throws -> AsyncThrowingStream<RemoteChangeNotification, Error>? {
        let task = Task { try await client.changes() }
        let command = await host.nextCommand()
        XCTAssertEqual(command["method"].string, "GET")
        XCTAssertEqual(command["path"].string, "/v1/changes/subscribe")
        if status == 200 { try await host.reply(command, FakeHost.change("0")) }
        else { try await host.chunk(command, Data(), status: status) }
        return try await task.value
    }
    private func health(_ client: RelayClient, _ host: FakeHost) async throws {
        let task = Task { try await client.request("GET", "/v1/health") }
        let command = await host.nextCommand()
        try await host.reply(command)
        let value = try await task.value
        XCTAssertTrue(value["ok"].bool)
    }

    private func until(_ predicate: @Sendable () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Transport did not reach expected state", file: file, line: line)
        throw RemoteFailure("Test synchronization failed.")
    }

    private func assertFailure(_ task: Task<RemoteJSON, Error>, kind: RemoteFailure.Kind, message: String? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Expected delivery failure", file: file, line: line) }
        catch {
            XCTAssertEqual((error as? RemoteFailure)?.kind, kind, "\(error)", file: file, line: line)
            if let message { XCTAssertEqual(error.localizedDescription, message, file: file, line: line) }
        }
    }

    func testPreflightFailuresAreNotDispatchedAndDoNotAdvanceHPKE() async throws {
        let host = try FakeHost(), socket = FakeSocket(host)
        let client = RelayClient(makeSocket: { _ in socket })
        await assertFailure(Task { try await client.request("DELETE", "/v1/conversations/never") }, kind: .notDispatched, message: "Connect to the agent first.")
        try await client.connect(host.paired)
        for body: RemoteJSON in [.number(.nan), .number(.infinity), .string(String(repeating: "x", count: 196_608))] {
            await assertFailure(Task { try await client.request("POST", "/v1/conversations", body: body) }, kind: .notDispatched)
        }
        let before = await host.commands
        XCTAssertTrue(before.isEmpty)
        try await health(client, host)
        await client.disconnect()
    }

    func testAuthenticatedRejectionMetadataIsRequiredAndSafeMessagesSurvive() async throws {
        let (client, host) = try await connected()
        let cases: [(Int, RemoteJSON, RemoteFailure.Kind)] = [
            (400, .object(["error": .string("Invalid title."), "delivery": .string("rejected")]), .rejected),
            (503, .object(["error": .string("No work was accepted."), "delivery": .string("rejected")]), .rejected),
            (500, .object(["error": .string("Save failed after actions. Inspect state.")]), .uncertain),
            (409, .object(["error": .string("Conversation requires storage recovery.")]), .uncertain),
            (401, .object(["error": .string("Legacy authorization failure.")]), .uncertain),
            (403, .object(["error": .string("Legacy authorization failure.")]), .uncertain),
            (400, .object(["error": .string("Unknown evidence."), "delivery": .string("future")]), .uncertain),
            (400, .object(["error": .string("Malformed evidence."), "delivery": .bool(true)]), .uncertain),
            (409, .object(["error": .string("Request rejected.")]), .uncertain),
        ]
        for (status, body, kind) in cases {
            let task = Task { try await client.request("DELETE", "/v1/conversations/once") }
            let command = await host.nextCommand()
            try await host.reply(command, body, status: status)
            await assertFailure(task, kind: kind, message: body["error"].string)
            try await health(client, host) // drain errors and preserve both HPKE directions
        }
        let legacy = Task { try await client.request("POST", "/v1/conversations") }
        let command = await host.nextCommand()
        try await host.chunk(command, Data("legacy non-JSON failure".utf8), status: 500)
        await assertFailure(legacy, kind: .uncertain, message: "Request failed (HTTP 500). Inspect agent state before continuing.")
        try await health(client, host)
        let commands = await host.commands
        XCTAssertEqual(commands.count, (cases.count + 1) * 2, "Failures must never replay commands")
        await client.disconnect()
    }

    func testAvailabilityEndpointErrorsExposeAuthenticatedStatusWithoutRetryOrDeliveryInference() async throws {
        let (client, host) = try await connected()
        for status in [404, 405, 501] {
            let task = Task { try await client.request("POST", "/v1/tools/availability", body: .object(["names": .array([]), "model": .string("fixture/model")])) }
            let command = await host.nextCommand()
            XCTAssertEqual(command["method"].string, "POST")
            XCTAssertEqual(command["path"].string, "/v1/tools/availability")
            try await host.chunk(command, Data("Legacy non-JSON error".utf8), status: status)
            do { _ = try await task.value; XCTFail("Expected unsupported endpoint") }
            catch let failure as RemoteFailure {
                XCTAssertEqual(failure.statusCode, status)
                XCTAssertEqual(failure.kind, .uncertain, "HTTP status must not alter command delivery evidence")
            }
        }
        let commands = await host.commands
        XCTAssertEqual(commands.count, 3)
        await client.disconnect()
    }

    func testActiveLossIsUncertainButQueuedLossIsNotDispatchedAndReconnectNeverReplays() async throws {
        for mode in 0..<4 { // disconnect, lost reply, deadline, malformed successful body
            let old = try FakeHost(), fresh = try FakeHost()
            let factory = SocketFactory([old, fresh])
            let client = RelayClient(requestTimeout: .milliseconds(300), makeSocket: { factory.make($0) })
            try await client.connect(old.paired)
            let active = Task { try await client.request("POST", "/v1/conversations") }
            let command = await old.nextCommand()
            let queued = Task { try await client.request("DELETE", "/v1/conversations/never") }
            try await until { await client.queuedRequestCount == 1 }
            switch mode {
            case 0: await client.disconnect()
            case 1: old.pipe.close()
            case 2: break // exercise the real request timer, not the idle watchdog
            default: try await old.chunk(command, Data("{".utf8))
            }
            await assertFailure(active, kind: .uncertain)
            await assertFailure(queued, kind: .notDispatched)
            try await client.connect(fresh.paired)
            try await health(client, fresh)
            let oldCommands = await old.commands, freshCommands = await fresh.commands
            XCTAssertEqual(oldCommands.map { $0["method"].string! }, ["POST"])
            XCTAssertEqual(freshCommands.map { $0["method"].string! }, ["GET"])
            XCTAssertEqual(factory.count, 2)
            await client.disconnect()
        }
    }

    func testSendFailureAfterPeerAcceptanceIsUncertainAndQueuedCommandNeverLeaves() async throws {
        let (client, host) = try await connected()
        await host.holdNextCommandSend()
        let active = Task { try await client.request("POST", "/v1/conversations") }
        _ = await host.nextCommand() // real HPKE opened; remote effects are possible
        let queued = Task { try await client.request("DELETE", "/v1/conversations/never") }
        try await until { await client.queuedRequestCount == 1 }
        await host.failHeldSend()
        await assertFailure(active, kind: .uncertain)
        await assertFailure(queued, kind: .notDispatched)
        let commands = await host.commands
        XCTAssertEqual(commands.map { $0["method"].string! }, ["POST"])
    }

    func testRecordedChallengeAndEncryptedReadyCannotAuthenticateAFreshConnection() async throws {
        let (original, host) = try await connected()
        let recordedReady = await host.readyFrame
        let originalClientKey = await host.initialClientKey
        await original.disconnect()
        let replay = RecordedHandshakeSocket([host.challengeFrame, try XCTUnwrap(recordedReady)])
        let client = RelayClient(makeSocket: { _ in replay })
        do { try await client.connect(host.paired); XCTFail("Recorded handshake authenticated") } catch {}
        let connected = await client.isConnected
        XCTAssertFalse(connected)
        XCTAssertEqual(replay.sentFrames.count, 1, "Only the new hello may leave the unauthenticated connection")
        let newHello = try JSONDecoder().decode(RemoteJSON.self, from: Data(try XCTUnwrap(replay.sentFrames.first).utf8))
        XCTAssertNotEqual(newHello["encapsulatedKey"].string, originalClientKey)
        do { _ = try await client.request("DELETE", "/v1/conversations/never"); XCTFail("Replay enabled API dispatch") } catch {}
        XCTAssertEqual(replay.sentFrames.count, 1)
    }

    func testLegacyOrUnknownHandshakeVersionIsRejectedWithoutSendingHello() async throws {
        let host = try FakeHost()
        for version in [1, 3] {
            let frame: RemoteJSON = .object(["version": .number(Double(version)), "challenge": .string(String(repeating: "c", count: 64))])
            let socket = RecordedHandshakeSocket([String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)])
            let client = RelayClient(makeSocket: { _ in socket })
            do { try await client.connect(host.paired); XCTFail("Incompatible handshake accepted") } catch {}
            let connected = await client.isConnected
            XCTAssertFalse(connected)
            XCTAssertTrue(socket.sentFrames.isEmpty)
        }
    }

    func testAuthenticatedReadyMustDeclareV2BeforeAPIOrCapabilityAcceptance() async throws {
        for version: RemoteJSON in [.number(1), .number(3), .null, .string("2")] {
            let host = try FakeHost(readyFields: ["version": version, "changeNotifications": .bool(true)])
            let client = RelayClient(makeSocket: { _ in FakeSocket(host) })
            do { try await client.connect(host.paired); XCTFail("Incompatible ready accepted") } catch {}
            let connected = await client.isConnected, commands = await host.commands
            XCTAssertFalse(connected)
            XCTAssertTrue(commands.isEmpty)
        }
    }

    func testV2AuthenticatedReadyWithoutCapabilityNeverProbesItsAllowlist() async throws {
        for fields: [String: RemoteJSON] in [[:], ["changeNotifications": .bool(false)], ["futureCapability": .object([:])]] {
            let host = try FakeHost(readyFields: fields), socket = FakeSocket(host)
            let client = RelayClient(livenessTimeout: .milliseconds(50), makeSocket: { _ in socket })
            try await client.connect(host.paired)
            let stream = try await client.changes()
            XCTAssertNil(stream)
            let probes = await host.commands
            XCTAssertTrue(probes.isEmpty, "Old main rejects subscription at its allowlist with 403; don't probe")
            // Old hosts promise no heartbeats. Idle legacy polling connections stay usable.
            try await Task.sleep(for: .milliseconds(80))
            try await health(client, host)
            await client.disconnect()
        }
    }

    func testKnownCapabilityMustBeBooleanButUnknownReadyFieldsAreIgnored() async throws {
        for malformed: RemoteJSON in [.null, .string("true"), .number(1), .array([]), .object([:])] {
            let host = try FakeHost(readyFields: ["changeNotifications": malformed]), socket = FakeSocket(host)
            let client = RelayClient(makeSocket: { _ in socket })
            do { try await client.connect(host.paired); XCTFail("Malformed known capability accepted") } catch {}
            let connected = await client.isConnected, commands = await host.commands
            XCTAssertFalse(connected)
            XCTAssertTrue(commands.isEmpty)
        }
        let host = try FakeHost(readyFields: ["changeNotifications": .bool(true), "future": .string("unknown")])
        let client = RelayClient(makeSocket: { _ in FakeSocket(host) })
        try await client.connect(host.paired)
        _ = try await subscribe(client, host)
        await client.disconnect()
    }

    func testUnauthenticatedReadyCannotAdvertiseCapabilitiesOrAuthorizeAPI() async throws {
        let host = try FakeHost()
        // A relay can inject plaintext, but cannot manufacture the authenticated ready.
        host.pipe.push(#"{"ready":true,"changeNotifications":true}"#)
        let client = RelayClient(makeSocket: { _ in FakeSocket(host) })
        do { try await client.connect(host.paired); XCTFail("Plaintext ready authenticated") } catch {}
        do { _ = try await client.request("DELETE", "/v1/conversations/never"); XCTFail("Unauthenticated API dispatched") } catch {}
        let connected = await client.isConnected, commands = await host.commands
        XCTAssertFalse(connected)
        XCTAssertTrue(commands.isEmpty)
    }

    func testAuthenticatedAPIAuthRejectionsRemainErrorsWithoutDisconnectOrReplay() async throws {
        let (client, host) = try await connected()
        for status in [401, 403] {
            let mutation = Task { try await client.request("DELETE", "/v1/conversations/denied") }
            let command = await host.nextCommand()
            try await host.reply(command, .object(["error": .string("Not authorized.")]), status: status)
            do { _ = try await mutation.value; XCTFail("Auth rejection accepted") }
            catch {
                XCTAssertEqual(error.localizedDescription, "Not authorized.")
                XCTAssertEqual((error as? RemoteFailure)?.kind, .uncertain, "Legacy responses have no no-effect evidence")
            }
            try await health(client, host)
        }
        let commands = await host.commands
        XCTAssertEqual(commands.map { $0["method"].string! }, ["DELETE", "GET", "DELETE", "GET"])
        await client.disconnect()
    }

    func testQueuedDeleteCancellationInsidePrecedingCompletionCannotSealOrTransmit() async throws {
        let hook = DispatchHook()
        let (client, host) = try await connected(beforeDispatch: { hook.run() })
        let first = Task { try await client.request("POST", "/v1/conversations") }
        let accepted = await host.nextCommand()
        let deletion = Task { try await client.request("DELETE", "/v1/conversations/never") }
        try await until { await client.queuedRequestCount == 1 } // demonstrably enqueued
        // startNext owns the actor when this cancellation fires. Its asynchronous
        // cleanup CANNOT run before sealing; only the synchronous token can stop it.
        hook.set { deletion.cancel() }
        try await host.reply(accepted)
        _ = try await first.value
        do { _ = try await deletion.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        try await health(client, host) // verifies no skipped HPKE sequence, not just no DELETE
        let commands = await host.commands
        XCTAssertEqual(commands.map { $0["method"].string! }, ["POST", "GET"])
        await client.disconnect()
    }

    func testRequestQueueIsBoundedAndCancelledQueuedCommandsAreNeverSent() async throws {
        let (client, host) = try await connected()
        let first = Task { try await client.request("POST", "/v1/conversations") }
        let accepted = await host.nextCommand()
        let queued = (0..<64).map { index in Task { try await client.request("DELETE", "/v1/conversations/\(index)") } }
        try await until { await client.queuedRequestCount == 64 }
        do { _ = try await client.request("DELETE", "/v1/conversations/overflow"); XCTFail("Queue was unbounded") }
        catch {
            XCTAssertEqual(error.localizedDescription, "Too many pending requests.")
            XCTAssertEqual((error as? RemoteFailure)?.kind, .notDispatched)
        }
        queued.forEach { $0.cancel() }
        for task in queued { do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} }
        try await host.reply(accepted); _ = try await first.value
        try await health(client, host)
        let commands = await host.commands
        XCTAssertEqual(commands.count, 2)
        await client.disconnect()
    }

    func testAwaitedConsumerReplacementPreservesInFlightMutationAndSinglePump() async throws {
        let (client, host) = try await connected()
        let stream = try await subscribe(client, host)!
        let consumer = Task { for try await _ in stream {} }
        let mutation = Task { try await client.request("POST", "/v1/conversations") }
        let command = await host.nextCommand()
        consumer.cancel(); _ = try? await consumer.value
        await client.stopChanges() // independent of asynchronous onTermination cleanup
        let replacement = Task { try await client.changes() }
        try await until { await client.queuedRequestCount == 1 }
        try await host.notice("1")
        try await host.reply(command); _ = try await mutation.value
        let subscribe = await host.nextCommand()
        XCTAssertEqual(subscribe["path"].string, "/v1/changes/subscribe")
        try await host.reply(subscribe, FakeHost.change("2"))
        var iterator = try await replacement.value!.makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertEqual(initial?.catalog, "2")
        try await host.notice("3")
        let next = try await iterator.next()
        XCTAssertEqual(next?.catalog, "3")
        try await health(client, host)
        let commands = await host.commands
        XCTAssertEqual(commands.filter { $0["method"].string == "POST" }.count, 1)
        XCTAssertFalse(host.pipe.hadConcurrentReads)
        await client.disconnect()
    }

    func testHalfOpenSubscribedSocketExpiresWithoutPollingOrReplay() async throws {
        let (client, host) = try await connected(livenessTimeout: .milliseconds(100))
        let stream = try await subscribe(client, host)!
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        try await until { !(await client.isConnected) }
        do { _ = try await iterator.next(); XCTFail("Half-open stream remained alive") } catch {}
        let commands = await host.commands
        XCTAssertEqual(commands.count, 1, "Watchdog is timer-driven, not HTTP polling")
    }

    func testAuthenticatedTrafficRenewsWatchdogAndActiveMutationGetsItsOwnDeadline() async throws {
        let (client, host) = try await connected(livenessTimeout: .milliseconds(150))
        _ = try await subscribe(client, host)
        // Authenticated reply chunks as well as heartbeats renew liveness.
        for revision in 1...6 {
            try await Task.sleep(for: .milliseconds(40))
            try await host.notice(String(revision))
            try await health(client, host) // ordered-pump barrier
        }
        let mutation = Task { try await client.request("DELETE", "/v1/conversations/once") }
        let command = await host.nextCommand()
        try await Task.sleep(for: .milliseconds(350)) // longer than idle timeout, less than request deadline
        let connected = await client.isConnected
        XCTAssertTrue(connected, "Idle watchdog must not truncate a legitimate active request")
        try await host.chunk(command, Data("{".utf8), done: false)
        try await Task.sleep(for: .milliseconds(40))
        try await host.chunk(command, Data("}".utf8)); _ = try await mutation.value
        try await until { !(await client.isConnected) }
        let commands = await host.commands
        XCTAssertEqual(commands.filter { $0["method"].string == "DELETE" }.count, 1)
    }

    func testWatchdogFromOldGenerationCannotDisconnectReconnectedLegacyHost() async throws {
        let old = try FakeHost(), fresh = try FakeHost(readyFields: [:])
        let factory = SocketFactory([old, fresh])
        let client = RelayClient(livenessTimeout: .milliseconds(80), makeSocket: { factory.make($0) })
        try await client.connect(old.paired)
        _ = try await subscribe(client, old)
        await client.disconnect()
        try await client.connect(fresh.paired)
        let changes = try await client.changes()
        XCTAssertNil(changes, "Capabilities must also reset across generations")
        try await Task.sleep(for: .milliseconds(180))
        try await health(client, fresh)
        XCTAssertEqual(factory.count, 2)
        await client.disconnect()
    }

    func testPublicRevisionShapeRoundTripsWithoutNumericConversion() throws {
        let value = RemoteChangeNotification(epoch: "restart", catalog: "18446744073709551615", conversations: ["id": "9007199254740993"])
        XCTAssertEqual(try JSONDecoder().decode(RemoteChangeNotification.self, from: JSONEncoder().encode(value)), value)
    }

    func testSinglePumpDemuxesFragmentedRepliesAndNewestNotifications() async throws {
        let (client, host) = try await connected()
        let stream = try await subscribe(client, host)!
        var iterator = stream.makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertEqual(initial?.catalog, "0")
        let request = Task { try await client.request("GET", "/v1/library") }
        let command = await host.nextCommand()
        try await host.chunk(command, Data(#"{"ok":"#.utf8), done: false)
        for revision in 1...50 { try await host.notice(String(revision)) }
        try await host.chunk(command, Data("true}".utf8))
        let result = try await request.value
        XCTAssertTrue(result["ok"].bool)
        let latest = try await iterator.next()
        XCTAssertEqual(latest?.catalog, "50") // bufferingNewest(1), not fifty queued notices
        XCTAssertFalse(host.pipe.hadConcurrentReads)
        await client.disconnect()
        do { _ = try await iterator.next(); XCTFail("Disconnect must end observation with a failure") } catch {}
    }

    func testOnlyExplicit404Or405FallsBackAndAPIRejectionsPreserveHPKE() async throws {
        for status in [404, 405, 403, 500] {
            let (client, host) = try await connected()
            do {
                let stream = try await subscribe(client, host, status: status)
                XCTAssertTrue(status == 404 || status == 405)
                XCTAssertNil(stream)
            } catch { XCTAssertTrue(status == 403 || status == 500) }
            // Same context after error, in BOTH directions.
            try await health(client, host)
            await client.disconnect()
        }
        let (client, host) = try await connected()
        let subscribe = Task { try await client.changes() }
        _ = await host.nextCommand()
        host.pipe.close()
        do { _ = try await subscribe.value; XCTFail("Disconnect is not unsupported") } catch {}
        await client.disconnect()
    }

    func testMalformedSuccessfulSubscriptionThrowsInsteadOfFallingBack() async throws {
        let (client, host) = try await connected()
        let task = Task { try await client.changes() }
        let command = await host.nextCommand()
        try await host.reply(command, .object(["catalog": .number(1)]))
        do { _ = try await task.value; XCTFail("Malformed notification accepted") } catch {}
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }

    func testConsumerAndAcceptedMutationCancellationDoNotCancelOrReplayMutation() async throws {
        let (client, host) = try await connected()
        let stream = try await subscribe(client, host)!
        let consumer = Task { for try await _ in stream {} }
        let mutation = Task { try await client.request("POST", "/v1/conversations") }
        let accepted = await host.nextCommand()
        consumer.cancel(); _ = try? await consumer.value
        mutation.cancel()
        do { _ = try await mutation.value; XCTFail("Cancelled caller still waiting") } catch is CancellationError {} catch { XCTFail("Wrong cancellation error: \(error)") }
        let queued = Task { try await client.request("GET", "/v1/health") }
        try await host.notice("1") // still opened and discarded after cancellation
        try await host.reply(accepted)
        let read = await host.nextCommand()
        XCTAssertEqual(read["path"].string, "/v1/health")
        try await host.notice("2")
        try await host.reply(read)
        _ = try await queued.value
        let commands = await host.commands
        XCTAssertEqual(commands.map { $0["method"].string! }, ["GET", "POST", "GET"])
        XCTAssertFalse(host.pipe.hadConcurrentReads)
        await client.disconnect()
    }

    func testCancelledSubscribeIsDrainedAndDoesNotPoisonTheNextRequest() async throws {
        let (client, host) = try await connected()
        let subscribe = Task { try await client.changes() }
        let accepted = await host.nextCommand()
        subscribe.cancel()
        do { _ = try await subscribe.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        try await host.reply(accepted, FakeHost.change("0"))
        try await host.notice("1")
        try await health(client, host)
        let stream = try await self.subscribe(client, host)!
        var iterator = stream.makeAsyncIterator()
        let initial = try await iterator.next()
        XCTAssertEqual(initial?.catalog, "0")
        await client.disconnect()
    }

    func testQueuedCancellationAndDisconnectEndPendingReadsWithoutReplay() async throws {
        let (client, host) = try await connected()
        let first = Task { try await client.request("POST", "/v1/conversations") }
        let accepted = await host.nextCommand()
        let cancelled = Task { try await client.request("DELETE", "/v1/conversations/never") }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        try await host.reply(accepted)
        _ = try await first.value
        try await health(client, host)
        let stream = try await subscribe(client, host)!
        let active = Task { try await client.request("GET", "/v1/library") }
        _ = await host.nextCommand()
        let queued = Task { try await client.request("GET", "/v1/conversations") }
        await client.disconnect()
        do { _ = try await active.value; XCTFail("Active request not ended") } catch {}
        do { _ = try await queued.value; XCTFail("Queued request not ended") } catch {}
        var iterator = stream.makeAsyncIterator()
        do { while try await iterator.next() != nil {}; XCTFail("Stream did not report disconnect") } catch {}
        let commands = await host.commands
        XCTAssertFalse(commands.contains { $0["method"].string == "DELETE" })
    }

    func testReconnectIgnoresStaleReceiveCallbacksAndRequiresFreshOptIn() async throws {
        let old = try FakeHost(delayClose: true), fresh = try FakeHost()
        let factory = SocketFactory([old, fresh])
        let client = RelayClient(makeSocket: { factory.make($0) })
        try await client.connect(old.paired)
        _ = try await subscribe(client, old)
        await client.disconnect()
        try await client.connect(fresh.paired)
        // Wake the old, cancelled pump AFTER the new handshake. It must neither
        // open this with the new channel nor disconnect the new socket.
        old.pipe.push("{}")
        try await health(client, fresh)
        XCTAssertEqual(factory.count, 2)
        let freshCommands = await fresh.commands
        XCTAssertEqual(freshCommands.count, 1)
        XCTAssertEqual(freshCommands.first?["path"].string, "/v1/health")
        _ = try await subscribe(client, fresh)
        await client.disconnect(); old.pipe.close(force: true)
    }

    func testRejectsInvalidReplyIDsStatusTypesSizesAndUnsolicitedFrames() async throws {
        for mode in 0..<8 {
            let (client, host) = try await connected()
            let task = Task { try await client.request("GET", "/v1/health") }
            let command = await host.nextCommand()
            var fields: [String: RemoteJSON] = ["id": command["id"], "status": .number(200), "body": .string(Data("{}".utf8).base64EncodedString()), "done": .bool(true)]
            switch mode {
            case 0: fields["id"] = .string(UUID().uuidString)
            case 1: fields["status"] = .number(700)
            case 2: fields["status"] = .number(200.5)
            case 3: fields["done"] = .string("true")
            case 4: fields["body"] = .string(Data(repeating: 0, count: 48 * 1024 + 1).base64EncodedString())
            case 5:
                try await host.chunk(command, Data("{".utf8), status: 200, done: false)
                fields["status"] = .number(201)
            case 6: fields = ["notification": FakeHost.change("0")]
            default: host.pipe.push(String(repeating: "x", count: 1024 * 1024 + 1))
            }
            if mode != 7 { try await host.frame(.object(fields)) }
            do { _ = try await task.value; XCTFail("Accepted invalid frame \(mode)") }
            catch { XCTAssertEqual((error as? RemoteFailure)?.kind, .uncertain) }
            let connected = await client.isConnected
            XCTAssertFalse(connected)
            let count = await host.commands.count
            XCTAssertEqual(count, 1)
        }
    }
}
