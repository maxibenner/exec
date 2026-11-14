#if DEBUG && targetEnvironment(simulator)
import Foundation
import ExecRemote

/// Simulator-only data for UI regression checks. Never load a saved host, access
/// Keychain, or start observation/transport when this launch argument is present.
@MainActor enum RemoteUIFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-fixture") }
    static var host: PairedHost {
        let invitation = try! RemoteJSON.object([
            "version": .number(1), "relay": .string("ws://127.0.0.1:1"),
            "route": .string(String(repeating: "0", count: 64)),
            "hostKey": .string(Data(repeating: 0, count: 32).base64EncodedString()),
            "expires": .number(0), "localDevelopment": .bool(true)
        ]).decoded(PairingInvitation.self)
        return PairedHost(invitation: invitation, deviceName: "UI Fixture")
    }
    static var conversations: [RemoteJSON] {
        (1...6).map { index in
            .object(["id": .string("fixture-\(index)"), "workspace": .string("/Fixture/Workspace"),
                     "metadata": .object(["title": .string("Session \(index)"),
                                          "activityAt": .number(Date().timeIntervalSince1970 * 1000 - Double(index) * 1000)])])
        }
    }
    private static var deleted: Set<String> = []
    static func request(_ method: String, _ path: String) async throws -> RemoteJSON {
        if method == "DELETE" {
            try await Task.sleep(for: .seconds(3))
            if ProcessInfo.processInfo.arguments.contains("--delete-fails") { throw RemoteFailure("Fixture deletion failed.") }
            deleted.insert(String(path.split(separator: "/").last!))
            return .null
        }
        if path == "/v1/conversations" {
            if !deleted.isEmpty, ProcessInfo.processInfo.arguments.contains("--refresh-fails") {
                throw RemoteFailure("Fixture refresh failed.")
            }
            return .array(conversations.filter { !deleted.contains($0["id"].string ?? "") })
        }
        if path == "/v1/library" { return .object([:]) }
        if method == "GET", path.hasPrefix("/v1/conversations/") { return snapshot(String(path.split(separator: "/").last!)) }
        throw RemoteFailure("Unsupported UI fixture request.")
    }
    static func snapshot(_ id: String) -> RemoteJSON {
        let messages: [RemoteJSON] = (1...40).map { index in
            .object(["id": .string("message-\(index)"), "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                     "text": .string("Message \(index)\nThis is an isolated transcript for checking native navigation underlap, scrolling, and composer spacing."),
                     "status": .string("completed")])
        }
        return .object(["id": .string(id), "metadata": .object(["title": .string("Session 1")]),
                        "messages": .array(messages),
                        "operation": .object(["id": .string("fixture-operation"), "state": .string("running")])])
    }
}
#endif
