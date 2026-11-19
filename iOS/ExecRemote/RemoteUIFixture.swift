#if DEBUG && targetEnvironment(simulator)
import Foundation
import ExecRemote

/// Simulator-only data for UI regression checks. Inject a fake transport and
/// in-memory host storage, exercising the real store lifecycle without Keychain
/// or network access.
@MainActor enum RemoteUIFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-fixture") }
    static let preferences: UserDefaults = {
        let suite = "com.numbersoffice.exec.remote.ui-fixture"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.removePersistentDomain(forName: suite)
        return preferences
    }()
    static func makeStore() -> RemoteStore {
        let unpaired = ProcessInfo.processInfo.arguments.contains("--unpaired-fixture")
        let offlineActions = ProcessInfo.processInfo.arguments.contains("--offline-actions-fixture")
        let recovering = ProcessInfo.processInfo.arguments.contains("--recovering-host-fixture")
        let queuedRecovery = ProcessInfo.processInfo.arguments.contains("--offline-reconnect-fixture")
        let shortDeadline = ProcessInfo.processInfo.arguments.contains("--offline-expiry-fixture")
        let coldOffline = ProcessInfo.processInfo.arguments.contains("--cold-offline-fixture")
        let delayedStartup = ProcessInfo.processInfo.arguments.contains("--delayed-startup-fixture")
        let transport = FixtureTransport()
        let store = RemoteStore(client: transport, loadHost: { unpaired ? nil : host }, saveHost: { _ in }, forgetHost: {}, sleep: { delay in
            // Allow one batched offline layout sample (including a sheet
            // presentation), then exercise the real observer's automatic retry.
            // Tests must still verify the banner survived their offline sample.
            let connected = await transport.isConnected
            let interval = recovering && !connected ? (queuedRecovery ? 20.0 : 30.0) : delay
            try await Task.sleep(for: .seconds(interval))
        }, bufferSleep: {
            // Short deadlines are injected only in explicit expiry UI fixtures.
            // Explicit-cancel checks must not race the normal 30-second expiry.
            try await Task.sleep(for: .seconds(shortDeadline ? 12 : offlineActions ? 300 : 30))
        })
        if !delayedStartup {
            store.conversations = unpaired ? [] : conversations
            store.library = library
            store.models = models
        }
        if offlineActions, !coldOffline, case .object(var cached) = snapshot("fixture-1") {
            // Keep a completed transcript resident, as after losing a previously
            // connected host, so offline checks exercise real scroll content.
            cached["operation"] = conversations[0]["operation"]
            store.selected = "fixture-1"
            store.snapshot = .object(cached)
            store.selected = nil
        }
        return store
    }
    static var host: PairedHost {
        let invitation = try! RemoteJSON.object([
            "version": .number(1), "relay": .string("ws://127.0.0.1:1"),
            "route": .string(String(repeating: "0", count: 64)),
            "hostKey": .string(Data(repeating: 0, count: 32).base64EncodedString()),
            "expires": .number(0), "localDevelopment": .bool(true)
        ]).decoded(PairingInvitation.self)
        return PairedHost(invitation: invitation, deviceName: "UI Fixture")
    }
    private static let activityTime = Date().timeIntervalSince1970 * 1000
    static var conversations: [RemoteJSON] {
        let count = ProcessInfo.processInfo.arguments.contains("--recovering-host-fixture") ? 12 : 6
        return (1...count).map { index in
            var metadata: [String: RemoteJSON] = [
                "title": .string("Session \(index)"),
                "activityAt": .number(activityTime - Double(index) * 1000)
            ]
            if ProcessInfo.processInfo.arguments.contains("--subagent-fixture"), [2, 3].contains(index) {
                metadata["parent"] = .object(["sessionId": .string("fixture-1")])
            }
            return .object(["id": .string("fixture-\(index)"), "workspace": .string("/Fixture/Workspace"),
                            "operation": .object(["state": .string(ProcessInfo.processInfo.arguments.contains("--activity-fixture")
                                ? ["running", "awaiting_approval", "cancelling", "completed", "failed", "completed"][index - 1] : "completed")]),
                            "metadata": .object(metadata)])
        }
    }
    static var models: [RemoteJSON] {
        [.object(["id": .string("fixture/reasoning"), "name": .string("Fixture Reasoning"),
                  "defaultEffort": .string("high"),
                  "efforts": .array([.object(["id": .string("low"), "name": .string("Low")]),
                                     .object(["id": .string("high"), "name": .string("High")])])]),
         .object(["id": .string("fixture/basic"), "name": .string("Fixture Basic"), "efforts": .array([])])]
    }
    private static var updatedLibrary: RemoteJSON?
    private static var promptSaves = 0
    static var library: RemoteJSON {
        let disabled: [String]
        if ProcessInfo.processInfo.arguments.contains("--orchestration-defaults-fixture") {
            disabled = ["shell", "delegate", "wait", "temporarily_unavailable"]
        } else {
            disabled = ProcessInfo.processInfo.arguments.contains("--all-tools-enabled") ? [] : ["shell"]
        }
        return updatedLibrary ?? .object(["defaultModel": .string("fixture/reasoning"), "automaticTitles": .bool(true),
                 "defaultDisabledTools": .array(disabled.map(RemoteJSON.string)),
                 "settings": .object(["systemPrompt": .string("Synthetic fixture instructions"),
                                      "autoApprove": .bool(true), "effort": .string("high")])])
    }
    private static let folders: [String: [String]] = [
        "/": ["Fixture"], "/Fixture": ["Projects", "Workspace"],
        "/Fixture/Projects": ["Example"], "/Fixture/Projects/Example": [],
        "/Fixture/Workspace": ["Sources", "Tests", "Unavailable"],
        "/Fixture/Workspace/Sources": ["App"], "/Fixture/Workspace/Sources/App": [],
        "/Fixture/Workspace/Tests": []
    ]
    private static var created: [RemoteJSON] = []
    private static var deleted: Set<String> = []
    static func request(_ method: String, _ path: String, body: RemoteJSON?) async throws -> RemoteJSON {
        if let response = try await TranscriptUIFixture.request(method, path, body: body) { return response }
        if method == "DELETE" {
            try await Task.sleep(for: .seconds(3))
            if ProcessInfo.processInfo.arguments.contains("--delete-fails") { throw RemoteFailure("Fixture deletion failed.") }
            deleted.insert(String(path.split(separator: "/").last!))
            return .null
        }
        if method == "POST", path == "/v1/workspaces/browse" {
            return try await browse(body?["path"].string ?? "/Fixture")
        }
        if method == "POST", path == "/v1/conversations" {
            return try create(body ?? .null)
        }
        if method == "GET", path == "/v1/conversations" {
            if !deleted.isEmpty, ProcessInfo.processInfo.arguments.contains("--refresh-fails") {
                throw RemoteFailure("Fixture refresh failed.")
            }
            return .array((conversations + created).filter { !deleted.contains($0["id"].string ?? "") })
        }
        if method == "GET", path == "/v1/models" { return .array(models) }
        if method == "PATCH", path == "/v1/library" { return try await patchLibrary(body ?? .null) }
        if method == "GET", path == "/v1/library" {
            if updatedLibrary != nil, ProcessInfo.processInfo.arguments.contains("--settings-refresh-fails") {
                throw RemoteFailure("Fixture settings refresh failed.")
            }
            return library
        }
        if method == "GET", path.hasPrefix("/v1/conversations/"), path.contains("/sync") {
            let id = String(path.split(separator: "/")[2])
            if ProcessInfo.processInfo.arguments.contains("--session-title-fixture") {
                try await Task.sleep(for: .seconds(5))
            }
            let full = snapshot(id)
            let messages = full["messages"].array
            let incremental = path.contains("?after=")
            guard case .object(var fields) = full else { throw RemoteFailure("Invalid UI fixture.") }
            fields["messages"] = .array(incremental ? Array(messages.suffix(1)) : messages)
            return .object(["snapshot": .object(fields),
                            "offset": .number(incremental ? Double(max(0, messages.count - 1)) : 0),
                            "total": .number(Double(messages.count)), "reset": .bool(!incremental),
                            "prefix": messages.isEmpty ? .null : .string(String(repeating: "a", count: 64))])
        }
        throw RemoteFailure("Unsupported UI fixture request.")
    }
    private static func patchLibrary(_ body: RemoteJSON) async throws -> RemoteJSON {
        guard case .object(let patch) = body, case .object(var fields) = library,
              patch.keys.allSatisfy({ ["automaticTitles", "defaultModel", "settings"].contains($0) }) else {
            throw RemoteFailure("Invalid fixture settings patch.")
        }
        if body["settings"]["systemPrompt"].string != nil {
            promptSaves += 1
            if ProcessInfo.processInfo.arguments.contains("--slow-settings-save") {
                try await Task.sleep(for: .seconds(3))
            }
            if promptSaves == 1, ProcessInfo.processInfo.arguments.contains("--settings-save-fails") {
                // Simulate another client's edit arriving on a background read
                // after rejection. A dirty, unfocused draft must survive it.
                fields["automaticTitles"] = .bool(false)
                fields["settings"] = .object(["systemPrompt": .string("Refreshed fixture instructions"),
                                              "autoApprove": .bool(true), "effort": .string("high")])
                updatedLibrary = .object(fields)
                throw RemoteFailure("Fixture settings save failed.")
            }
        }
        for (key, value) in patch {
            if key == "settings" {
                guard case .object(let changes) = value, case .object(var settings) = fields[key],
                      changes.keys.allSatisfy({ ["autoApprove", "systemPrompt"].contains($0) }) else {
                    throw RemoteFailure("Invalid fixture agent settings.")
                }
                settings.merge(changes) { _, new in new }
                fields[key] = .object(settings)
            } else { fields[key] = value }
        }
        updatedLibrary = .object(fields)
        return library
    }
    private static func browse(_ path: String) async throws -> RemoteJSON {
        // Delay just Sources so UI checks can choose the displayed parent, or
        // navigate to Tests and verify that the older reply cannot replace it.
        if path == "/Fixture/Workspace/Sources", ProcessInfo.processInfo.arguments.contains("--slow-folders") {
            try await Task.sleep(for: .seconds(3))
        }
        guard let children = folders[path] else { throw RemoteFailure("Fixture folder is unavailable.") }
        let directories: [RemoteJSON] = children.map { name in
            .object(["name": .string(name), "path": .string(path == "/" ? "/\(name)" : "\(path)/\(name)")])
        }
        return .object(["path": .string(path), "parent": path == "/" ? .null : .string((path as NSString).deletingLastPathComponent),
                        "directories": .array(directories), "truncated": .bool(false)])
    }
    private static func create(_ body: RemoteJSON) throws -> RemoteJSON {
        guard case .object(let fields) = body, let workspace = body["workspace"].string,
              folders[workspace] != nil, models.contains(where: { $0["id"] == body["model"] }) else {
            throw RemoteFailure("Invalid fixture session configuration.")
        }
        if ProcessInfo.processInfo.arguments.contains("--orchestration-defaults-fixture") {
            guard fields["disabledTools"] == .array(["shell", "temporarily_unavailable"].map(RemoteJSON.string)),
                  fields["settings"] == library["settings"] else {
                throw RemoteFailure("Fixture creation must enable orchestration and preserve other host defaults.")
            }
        }
        let disabled: [RemoteJSON]
        if let selection = fields["disabledTools"] {
            let supported = Set(RemoteSessionCreation.tools.map(\.id) + library["defaultDisabledTools"].array.compactMap(\.string))
            guard case .array(let names) = selection,
                  names.allSatisfy({ $0.string.map(supported.contains) ?? false }),
                  Set(names.compactMap(\.string)).count == names.count else {
                throw RemoteFailure("Invalid fixture tool selection.")
            }
            disabled = names
        } else {
            disabled = library["defaultDisabledTools"].array
        }
        let index = created.count + 1
        let value: RemoteJSON = .object([
            "id": .string("fixture-new-\(index)"), "workspace": .string(workspace), "model": body["model"],
            "configuration": .object(["model": body["model"], "settings": fields["settings"] ?? library["settings"]]),
            "metadata": .object(["title": .string("New Session \(index)"), "disabledTools": .array(disabled),
                                  "activityAt": .number(Date().timeIntervalSince1970 * 1000)]),
            "messages": .array([]), "operation": .object(["state": .string("completed")])
        ])
        created.append(value)
        return value
    }
    static func snapshot(_ id: String) -> RemoteJSON {
        if ProcessInfo.processInfo.arguments.contains("--bubble-fixture") {
            return .object(["id": .string(id), "metadata": .object(["title": .string("Bubble Width")]),
                "operation": .object(["state": .string("completed")]),
                "messages": .array(["Short", "A longer user message that wraps onto multiple lines in the same bubble width.", "One more"].enumerated().map { index, text in
                    .object(["id": .string("bubble-\(index)"), "role": .string("user"), "text": .string(text)])
                })])
        }
        if ProcessInfo.processInfo.arguments.contains("--tool-fixture") {
            let calls: [RemoteJSON] = ["first", "second"].map { call in
                .object(["id": .string(call), "name": .string("shell"),
                         "arguments": .object(["command": .string(call == "first" ? "pwd" : "sleep 5")])])
            }
            return .object([
                "id": .string(id), "metadata": .object(["title": .string("Tool Group")]),
                "messages": .array([
                    .object(["id": .string("user"), "role": .string("user"), "text": .string("Check the workspace")]),
                    .object(["id": .string("assistant"), "role": .string("assistant"), "text": .string(""), "calls": .array(calls)]),
                    .object(["id": .string("result"), "role": .string("tool"), "callID": .string("first"),
                             "text": .string("/Fixture/Workspace"), "outcome": .string("completed")])]),
                "operation": .object(["id": .string("fixture-operation"), "state": .string("running")]),
                "activeToolCallID": .string("second")
            ])
        }
        if let value = created.first(where: { $0.id == id }) { return value }
        var messages: [RemoteJSON] = (1...40).map { index in
            .object(["id": .string("message-\(index)"), "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                     "text": .string("\(id) message \(index)\nThis is an isolated transcript for checking native navigation underlap, scrolling, and composer spacing."),
                     "status": .string("completed")])
        }
        if ProcessInfo.processInfo.arguments.contains("--settings-fixture") {
            messages += [
                .object(["id": .string("shell-calls"), "role": .string("assistant"), "text": .string(""), "calls": .array([
                    .object(["id": .string("described-shell"), "name": .string("shell"), "arguments": .object([
                        "command": .string("printf 'fixture output'"), "description": .string("Print fixture output")])]),
                    .object(["id": .string("legacy-shell"), "name": .string("shell"), "arguments": .object([
                        "command": .string("pwd"), "description": .string("  ")])])])]),
                .object(["id": .string("shell-result"), "role": .string("tool"), "callID": .string("described-shell"),
                         "text": .string("Exit code: 0\nfixture output"), "outcome": .string("completed")]),
                .object(["id": .string("legacy-result"), "role": .string("tool"), "callID": .string("legacy-shell"),
                         "text": .string("Exit code: 0\n/Fixture/Workspace"), "outcome": .string("completed")])
            ]
        }
        if ProcessInfo.processInfo.arguments.contains("--expiry-scroll-fixture") {
            messages.append(.object(["id": .string("expiry-tail"), "role": .string("assistant"),
                                     "text": .string("Latest assistant reply."), "status": .string("completed")]))
        }
        let titlePrefix = ProcessInfo.processInfo.arguments.contains("--session-title-fixture") ? "Loaded Session" : "Session"
        return .object(["id": .string(id), "metadata": .object(["title": .string("\(titlePrefix) \(id.split(separator: "-").last ?? "")")]),
                        "messages": .array(messages),
                        "operation": .object(["id": .string("fixture-operation"), "state": .string("running")])])
    }
}

private actor FixtureTransport: RemoteTransport {
    var isConnected = false
    private var connectionAttempts = 0
    func connect(_ host: PairedHost) async throws {
        connectionAttempts += 1
        let arguments = ProcessInfo.processInfo.arguments
        if connectionAttempts == 1, arguments.contains("--delayed-startup-fixture")
            || arguments.contains("--delayed-host-failure-fixture") {
            try await Task.sleep(for: .seconds(10))
        }
        if arguments.contains("--settings-offline") || arguments.contains("--offline-actions-fixture")
            || (arguments.contains("--recovering-host-fixture") && connectionAttempts == 1) {
            throw RemoteFailure("Fixture host is offline.")
        }
        isConnected = true
    }
    func disconnect() { isConnected = false }
    func request(_ method: String, _ path: String, body: RemoteJSON?) async throws -> RemoteJSON {
        // Opening a cold session issues a read too. Hold its synthetic failure
        // until after the pending first handshake, so focus can be tested before
        // any actual failure without changing the store's failure latch.
        if ProcessInfo.processInfo.arguments.contains("--delayed-host-failure-fixture"), !isConnected {
            try await Task.sleep(for: .seconds(10))
        }
        if ProcessInfo.processInfo.arguments.contains("--offline-actions-fixture") {
            // An offline Send must stay buffered, never even attempt a fake command.
            precondition(method == "GET", "Offline actions must not dispatch host mutations.")
        }
        guard isConnected else { throw RemoteFailure("Fixture is disconnected.") }
        return try await RemoteUIFixture.request(method, path, body: body)
    }
}
#endif
