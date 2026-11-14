import XCTest
import CryptoKit
@testable import ExecRemote

final class RemoteTests: XCTestCase, @unchecked Sendable {
    func testRejectsUnsafeInvitations() throws {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        func invitation(_ relay: String, local: Bool, expires: Double = Date().timeIntervalSince1970 + 120) throws -> String {
            let value: RemoteJSON = .object(["version":.number(1),"relay":.string(relay),"route":.string(String(repeating:"a",count:64)),"hostKey":.string(key),"secret":.string(String(repeating:"b",count:64)),"expires":.number(expires),"localDevelopment":.bool(local)])
            return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
        XCTAssertThrowsError(try PairingInvitation.parse(invitation("ws://example.com", local:true)))
        XCTAssertThrowsError(try PairingInvitation.parse(invitation("ws://127.0.0.1:8787", local:false)))
        XCTAssertThrowsError(try PairingInvitation.parse(invitation("wss://user:password@example.com", local:false)))
        XCTAssertThrowsError(try PairingInvitation.parse(invitation("wss://example.com", local:false, expires:0)))
        XCTAssertNoThrow(try PairingInvitation.parse(invitation("ws://127.0.0.1:8787", local:true)))
    }

    #if os(macOS)
    func testRealRelayAndRustPairingSettingsAndRevocation() async throws {
        guard let backend = ProcessInfo.processInfo.environment["EXEC_TEST_BACKEND"],
              let relay = ProcessInfo.processInfo.environment["EXEC_TEST_RELAY"] else { throw XCTSkip("Set EXEC_TEST_BACKEND and EXEC_TEST_RELAY to isolated test binaries.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories:false, attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let apiPort = Int.random(in: 40000...44999), relayPort = Int.random(in: 45000...49999)
        let token = (0..<32).map { _ in String(format:"%02x", UInt8.random(in:0...255)) }.joined()
        func launch(_ path: String, _ args: [String], _ environment: [String:String]) throws -> Process {
            let process = Process(); process.executableURL = URL(fileURLWithPath:path); process.arguments = args
            process.environment = environment; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); return process
        }
        let relayProcess = try launch(relay, [], ["EXEC_RELAY_BIND":"127.0.0.1:\(relayPort)"])
        defer { if relayProcess.isRunning { relayProcess.terminate(); relayProcess.waitUntilExit() } }
        let agent = try launch(backend, ["--profile",directory.path,"--port",String(apiPort)], ["EXEC_AGENT_TOKEN":token,"HOME":directory.path])
        defer { if agent.isRunning { agent.terminate(); agent.waitUntilExit() } }
        let session = URLSession(configuration:.ephemeral); defer { session.invalidateAndCancel() }
        func local(_ method: String, _ path: String, _ body: RemoteJSON? = nil) async throws -> RemoteJSON {
            var request = URLRequest(url:URL(string:"http://127.0.0.1:\(apiPort)\(path)")!)
            request.httpMethod = method; request.timeoutInterval = 2
            request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization")
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody = try body.map { try JSONEncoder().encode($0) }
            let (data, response) = try await session.data(for:request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw RemoteFailure("Local fixture request failed.") }
            return try JSONDecoder().decode(RemoteJSON.self,from:data)
        }
        // Read-only readiness polling; no commands or provider calls are retried.
        var ready = false
        for _ in 0..<50 {
            if (try? await local("GET","/v1/health")) != nil { ready = true; break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertTrue(ready); guard ready else { return }
        _ = try await local("PUT","/v1/remote",.object(["enabled":.bool(true),"relay":.string("ws://127.0.0.1:\(relayPort)"),"localDevelopment":.bool(true)]))
        var connected = false
        for _ in 0..<50 {
            if try await local("GET","/v1/remote")["connected"].bool { connected = true; break }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertTrue(connected); guard connected else { return }
        let value = try await local("POST","/v1/remote/invitations",.object([:]))
        let invitation = try PairingInvitation.parse(String(decoding:JSONEncoder().encode(value),as:UTF8.self))
        var host = PairedHost(invitation:invitation,deviceName:"Integration fixture")
        let client = RelayClient()
        try await client.connect(host)
        let health = try await client.request("GET","/v1/health")
        XCTAssertEqual(health["version"].number,1)
        let workspace = directory.appendingPathComponent("Workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories:false)
        let folders = try await client.request("POST","/v1/workspaces/browse",body:.object(["path":.string(directory.path)]))
        XCTAssertTrue(folders["directories"].array.contains { $0["name"].string == "Workspace" })
        let created = try await client.request("POST","/v1/conversations",body:.object(["workspace":.string(workspace.path),"model":.string("deepseek/test")]))
        let deleted = try await client.request("DELETE","/v1/conversations/\(created["id"].string!)")
        XCTAssertTrue(deleted["deleted"].bool)
        let remaining = try await local("GET","/v1/conversations")
        XCTAssertTrue(remaining.array.isEmpty)

        _ = try await client.request("PATCH","/v1/library",body:.object(["settings":.object(["systemPrompt":.string("Shared fixture prompt")])]))
        let changed = try await local("GET","/v1/library")
        XCTAssertEqual(changed["settings"]["systemPrompt"].string,"Shared fixture prompt")
        _ = try await local("PATCH","/v1/library",.object(["automaticTitles":.bool(false)]))
        let observed = try await client.request("GET","/v1/library")
        XCTAssertFalse(observed["automaticTitles"].bool)
        XCTAssertEqual(observed["settings"]["systemPrompt"].string,"Shared fixture prompt")
        do { _ = try await client.request("GET","/v1/remote"); XCTFail("Remote administration must be denied") } catch {}
        await client.disconnect(); host.invitation.secret = nil
        try await client.connect(host) // Persistent device identity, no invitation reuse.
        let device = try await local("GET","/v1/remote")["devices"].array.first!["id"].string!
        _ = try await local("DELETE","/v1/remote/devices/\(device)")
        do { _ = try await client.request("GET","/v1/health"); XCTFail("Revoked socket remained authorized") } catch {}
        await client.disconnect()
    }
    #endif
}
