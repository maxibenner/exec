import AppKit
import Foundation
import SwiftUI
import WebKit

@MainActor struct RemoteAccessTests {
    private final class Credentials: CredentialStore {
        var data: Data?
        var reads = 0
        var writes = 0
        var failWrites = false
        func read(_ account: String) throws -> Data? { reads += 1; return data }
        func write(_ data: Data, account: String) throws { if failWrites { throw ExecError("Test save failure") }; writes += 1; self.data = data }
        func delete(_ account: String) throws { if account == PangolinConfiguration.account { data = nil } }
    }
    @MainActor private struct Fixture {
        let root: URL
        let preferences: UserDefaults
        let suite: String
        let sessions: SessionStore
        let provider: FakeProvider
        let library: ChatLibrary
        let ids: [UUID]

        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let suite = "ExecRemoteTests-" + UUID().uuidString
            let preferences = UserDefaults(suiteName: suite)!
            preferences.set(false, forKey: "generatedTitlesEnabled")
            let provider = FakeProvider()
            let sessions = SessionStore(directory: root.appendingPathComponent("sessions"))
            let workspace = try Workspace.load(root)
            var ids: [UUID] = []
            for name in ["Desktop conversation", "Phone conversation"] {
                let messages = [Message(role: .user, text: name), Message(role: .assistant, text: "Saved reply")]
                ids.append(try await sessions.save(SessionSnapshot(identity: provider.conversationIdentity,
                    workspace: workspace, selectedModel: "test", messages: messages, history: messages,
                    activeTurn: false, autoApproveTools: false), id: UUID(), select: false))
            }
            try await sessions.select(ids[0])
            let library = try ChatLibrary(provider: provider, sessions: sessions, preferences: preferences)
            library.restore()
            try await RemoteAccessTests().wait { !library.hasRunningOperations }
            return Self(root: root, preferences: preferences, suite: suite, sessions: sessions,
                        provider: provider, library: library, ids: ids)
        }
        func cleanup() {
            library.stopAll()
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
    private var siteConfiguration: PangolinConfiguration {
        PangolinConfiguration(executable: "/bin/echo", endpoint: "https://pangolin.example",
                              siteID: "fake-site", siteSecret: "fake-secret", resourceURL: "https://exec.example.com")
    }

    private var assets: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/RemoteUI")
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure(description: "Remote operation did not settle")
    }
    private func request(_ path: String, command: RemoteAPI.Command? = nil) throws -> RemoteHTTPRequest {
        RemoteHTTPRequest(method: command == nil ? "GET" : "POST", path: path,
                          headers: ["host": "exec.example.com", "origin": "https://exec.example.com",
                                    "x-exec-request": "1", "content-type": "application/json"],
                          body: try command.map { try JSONEncoder().encode($0) } ?? Data())
    }
    private func object(_ response: RemoteHTTPResponse) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    }

    func rejectsCrossOriginRebindingAndAmbiguousRequests() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let api = RemoteAPI(library: fixture.library, assets: ["/": RemoteHTTPResponse(contentType: "text/html", body: Data("Static shell".utf8))], allowedOrigins: ["https://exec.example.com"])
        var response = await api.handle(try request("/api/conversations"))
        try expect(response.status == 200)
        var cross = try request("/api/conversations")
        cross.headers["origin"] = "https://attacker.example"
        response = await api.handle(cross); try expect(response.status == 403)
        cross.headers["origin"] = "null"
        response = await api.handle(cross); try expect(response.status == 403)
        cross.headers["origin"] = "https://exec.example.com"
        cross.headers["sec-fetch-site"] = "cross-site"
        response = await api.handle(cross); try expect(response.status == 403)
        let navigationHeaders = ["host": "exec.example.com", "sec-fetch-site": "cross-site", "sec-fetch-mode": "navigate", "sec-fetch-dest": "document"]
        response = await api.handle(RemoteHTTPRequest(method: "GET", path: "/", headers: navigationHeaders))
        try expect(response.status == 200)
        response = await api.handle(RemoteHTTPRequest(method: "GET", path: "/api/conversations", headers: navigationHeaders))
        try expect(response.status == 403)
        response = await api.handle(RemoteHTTPRequest(method: "POST", path: "/", headers: navigationHeaders))
        try expect(response.status == 403)
        var invalidNavigation = navigationHeaders; invalidNavigation["host"] = "attacker.example"
        response = await api.handle(RemoteHTTPRequest(method: "GET", path: "/", headers: invalidNavigation))
        try expect(response.status == 403)
        let command = RemoteAPI.Command(serverID: api.serverID, requestID: UUID(), text: "Never submit")
        var noOrigin = try request("/api/conversations/\(fixture.ids[0])/messages", command: command)
        noOrigin.headers.removeValue(forKey: "origin")
        response = await api.handle(noOrigin); try expect(response.status == 403)
        response = await api.handle(try request("/api/conversations"))
        try expect(response.status == 200)
        let body = String(decoding: response.body, as: UTF8.self)
        try expect(!body.contains("test@example.com") && !body.contains("providerState") && !body.contains(fixture.root.path))
        var conditional = try request("/api/conversations"); conditional.headers["if-none-match"] = response.etag
        response = await api.handle(conditional); try expect(response.status == 304 && response.body.isEmpty)
        fixture.preferences.set(true, forKey: ToolDisplayPreferences.descriptiveShellTitlesKey)
        response = await api.handle(conditional)
        try expect(response.status == 200 && (try object(response))["descriptiveShellTitles"] as? Bool == true)
        fixture.preferences.set(false, forKey: ToolDisplayPreferences.descriptiveShellTitlesKey)
        response = await api.handle(try request("/api/conversations"))
        try expect((try object(response))["descriptiveShellTitles"] as? Bool == false)
        response = await api.handle(try request("/api/conversations/new", command: command)); try expect(response.status == 404)
        response = await api.handle(try request("/api/conversations/\(UUID())")); try expect(response.status != 200)
        for host in ["evil.example", "exec.example.com.attacker.test", "exec.example.com:80", "exec.example.com.", "exec.example.com@evil.example", "127.0.0.2:9417"] {
            var rebound = try request("/api/conversations")
            rebound.headers["host"] = host
            rebound.headers["origin"] = "https://" + host
            rebound.headers["x-forwarded-host"] = "exec.example.com"
            rebound.headers["remote-user"] = "trusted-user"
            response = await api.handle(rebound); try expect(response.status == 403)
            rebound = RemoteHTTPRequest(method: "GET", path: "/", headers: ["host": host])
            response = await api.handle(rebound); try expect(response.status == 403)
        }
        var simple = try request("/api/conversations", command: command)
        simple.headers.removeValue(forKey: "x-exec-request")
        response = await api.handle(simple); try expect(response.status == 403)
        api.invalidate()
        response = await api.handle(try request("/api/conversations")); try expect(response.status == 503)
        try expect(fixture.provider.children.allSatisfy { $0.inputs.isEmpty })

        let good = Data("POST /api/conversations HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{}".utf8)
        try expect(try RemoteHTTPRequest.parse(good.dropLast()) == nil)
        try expect(try RemoteHTTPRequest.parse(good)?.body == Data("{}".utf8))
        for raw in [
            "GET / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 999999\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: localhost\r\n\r\nGET / HTTP/1.1\r\n\r\n",
            "GET / HTTP/1.1\r\n Host: localhost\r\n\r\n",
            "OPTIONS / HTTP/1.1\r\nHost: localhost\r\n\r\n"
        ] { try expectFailure { _ = try RemoteHTTPRequest.parse(Data(raw.utf8)) } }
        try expectFailure { _ = try RemoteHTTPRequest.parse(Data(repeating: 65, count: 8193)) }
    }

    func preservesRunnersDraftsApprovalsAndCommandIdentity() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let library = fixture.library
        library.current.draft = "Desktop draft"
        let desktop = library.current
        let api = RemoteAPI(library: library, allowedOrigins: ["https://exec.example.com"])
        let path = "/api/conversations/\(fixture.ids[1])"
        var response = await api.handle(try request(path))
        try expect(response.status == 200 && library.current === desktop)
        let phone = library.openConversations.first { $0.currentSessionID == fixture.ids[1] }!
        phone.draft = "Another desktop draft"
        let provider = fixture.provider.children.last!
        let childCount = fixture.provider.children.count
        provider.holdOpen = true
        let command = RemoteAPI.Command(serverID: api.serverID, requestID: UUID(), text: "From phone")
        response = await api.handle(try request(path + "/messages", command: command)); try expect(response.status == 202)
        try await wait { provider.pending != nil }
        let operationID = phone.operationID!
        response = await api.handle(try request(path + "/messages", command: command)); try expect(response.status == 202)
        try expect(phone.messages.filter { $0.id == command.requestID }.count == 1)
        try expect(provider.inputs.count == 1 && fixture.provider.children.count == childCount)
        try expect(library.current === desktop && desktop.draft == "Desktop draft" && phone.draft == "Another desktop draft")
        try expect(!phone.autoApproveTools)
        response = await api.handle(try request("/api/commands/\(command.requestID)"))
        try expect(try object(response)["accepted"] as? Bool == true)
        var changed = command; changed.text = "Different input"
        response = await api.handle(try request(path + "/messages", command: changed)); try expect(response.status == 409)
        response = await api.handle(try request(path + "/stop", command: .init(serverID: api.serverID, requestID: UUID(), operationID: UUID())))
        try expect(response.status == 409 && !phone.isStopping)
        let stop = RemoteAPI.Command(serverID: api.serverID, requestID: UUID(), operationID: operationID)
        response = await api.handle(try request(path + "/stop", command: stop)); try expect(response.status == 202)
        await phone.waitUntilIdle()
        try expect(phone.messages.contains { $0.status == .interrupted })
        let restarted = RemoteAPI(library: library, allowedOrigins: ["https://exec.example.com"])
        response = await restarted.handle(try request(path + "/messages", command: command)); try expect(response.status == 409)
        response = await restarted.handle(try request("/api/commands/\(command.requestID)"))
        try expect(try object(response)["accepted"] as? Bool == false)
        try expect(try object(response)["serverID"] as? String != api.serverID.uuidString)
        // Reusing the same message ID after a new epoch cannot append it again.
        let replay = RemoteAPI.Command(serverID: restarted.serverID, requestID: command.requestID, text: "From phone")
        response = await restarted.handle(try request(path + "/messages", command: replay)); try expect(response.status == 409)

        // New input withdraws an approval using the same desktop path; it never
        // approves the old tool or changes the conversation's approval setting.
        provider.holdOpen = false
        provider.scripted = [[.toolCall(.init(id: "approval", name: "shell", arguments: #"{"command":"touch must-not-exist"}"#)), .completed], [.text("Changed direction"), .completed]]
        let first = RemoteAPI.Command(serverID: api.serverID, requestID: UUID(), text: "Do work")
        response = await api.handle(try request(path + "/messages", command: first)); try expect(response.status == 202)
        try await wait { phone.tools.pendingApproval != nil }
        let steer = RemoteAPI.Command(serverID: api.serverID, requestID: UUID(), text: "Do not do that")
        response = await api.handle(try request(path + "/messages", command: steer)); try expect(response.status == 202)
        await phone.waitUntilIdle()
        try expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("must-not-exist").path))
        try expect(!phone.autoApproveTools && phone.draft == "Another desktop draft")
        let preferred = try await fixture.sessions.preferredID(identity: fixture.provider.conversationIdentity)
        try expect(preferred == fixture.ids[0])
    }

    func configurationSaveFailurePreservesPreviousValue() throws {
        let suite = "ExecPangolinSave-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let credentials = Credentials()
        let access = RemoteAccess(credentials: credentials, preferences: preferences)
        let first = siteConfiguration
        try expect(access.apply(first))
        let saved = credentials.data
        credentials.failWrites = true
        var next = first; next.resourceURL = "https://new.example.com"
        try expect(!access.apply(next) && access.error != nil)
        access.dismissError()
        try expect(access.error == nil && access.configuration == first && credentials.data == saved)
        let restored = RemoteAccess(credentials: credentials, preferences: preferences)
        restored.loadConfiguration()
        try expect(restored.configuration == first)
        try expect(!preferences.dictionaryRepresentation().values.contains { String(describing: $0).contains("exec.example.com") })
    }

    func settingsRenderEditableFieldsAndSetup() async throws {
        _ = NSApplication.shared
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        fixture.library.settingsTab = .remoteAccess
        let previews = ProcessInfo.processInfo.environment["EXEC_SETTINGS_PREVIEWS"].map { URL(fileURLWithPath: $0) }
        if let previews { try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true) }
        for state in [RemoteAccess.ConnectionState.notConnected, .connecting, .connected] {
            let configured = state != .notConnected
            let launcher = PangolinConnectorTests.Launcher()
            let access = RemoteAccess(credentials: Credentials(), preferences: fixture.preferences,
                                      assetDirectory: assets, port: 0, connector: PangolinConnector(launcher: launcher))
            defer { access.setEnabled(false) }
            if configured {
                try expect(access.apply(siteConfiguration))
                access.attach(fixture.library); access.setEnabled(true)
                try await wait { launcher.children.count == 1 }
                if state == .connected {
                    launcher.children[0].isHealthy = true
                    try await wait { access.connectedToPangolin }
                }
            }
            try expect(access.connectionState == state)
            for dark in [false, true] {
                let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 680),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                defer { window.orderOut(nil); window.contentView = nil }
                let host = NSHostingView(rootView: SettingsView(store: fixture.library, canCheckForUpdates: false,
                    checkForUpdates: {}, remoteAccess: access).frame(width: 500, height: 680)
                    .environment(\.colorScheme, dark ? .dark : .light))
                window.contentView = host
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(150))
                host.layoutSubtreeIfNeeded()
                try expect(abs(host.fittingSize.width - 500) < 1 && host.fittingSize.height <= 681)
                func editableFields(_ view: NSView) -> [NSTextField] {
                    let own = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
                    return own + view.subviews.flatMap(editableFields)
                }
                let fields = editableFields(host)
                try expect(fields.count == 4 && fields.allSatisfy { $0.alignment == .right })
                let secret = fields.compactMap { $0 as? NSSecureTextField }.first
                try expect(secret != nil)
                guard secret!.bounds.width > 0 && secret!.bounds.width <= 144 else {
                    throw CheckFailure(description: "Secure input width: \(secret!.bounds.width)")
                }
                try expect(secret!.stringValue == (configured ? siteConfiguration.siteSecret : ""))
                if let previews, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to:
                        previews.appendingPathComponent("remote-\(state)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    func oldConfigurationCannotBypassConnectorSetup() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        for complete in [false, true] {
            fixture.preferences.set(true, forKey: "mobileAccessEnabled")
            var configuration = siteConfiguration
            if !complete { configuration.siteSecret = "" }
            var record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as! [String: Any]
            record["managed"] = false // An older saved listener-only configuration.
            let credentials = Credentials()
            credentials.data = try JSONSerialization.data(withJSONObject: record)
            let launcher = PangolinConnectorTests.Launcher()
            let access = RemoteAccess(credentials: credentials, preferences: fixture.preferences, assetDirectory: assets,
                                      port: 0, connector: PangolinConnector(launcher: launcher))
            defer { access.suspend() }
            access.attach(fixture.library)
            try expect(access.configuration == configuration)
            if complete {
                try await wait { launcher.children.count == 1 || access.error != nil }
                try expect(access.error == nil && access.listening && launcher.children.count == 1)
            } else {
                try expect(access.error != nil && !access.listening && !access.enabled && launcher.validations == 0)
                try expect(access.connectionState == .notConnected)
                try expect(access.apply(siteConfiguration))
                access.setEnabled(true)
                try await wait { launcher.children.count == 1 || access.error != nil }
                try expect(access.error == nil && launcher.children.count == 1)
                let saved = try JSONSerialization.jsonObject(with: credentials.data!) as! [String: Any]
                try expect(saved["managed"] == nil)
            }
            access.suspend()
            try expect(launcher.children[0].stops == 1)
        }
    }

    func connectionFailureDisablesWithoutStoppingAcceptedWork() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let credentials = Credentials(), launcher = PangolinConnectorTests.Launcher()
        let access = RemoteAccess(credentials: credentials, preferences: fixture.preferences, assetDirectory: assets,
                                  port: 0, connector: PangolinConnector(launcher: launcher))
        defer { access.suspend() }
        access.attach(fixture.library)
        try expect(access.apply(siteConfiguration))
        let running = fixture.library.current
        fixture.provider.children.first!.holdOpen = true
        try running.sendRemoteMessage("Keep this accepted work running", id: UUID())
        try await wait { fixture.provider.children.first!.pending != nil }
        access.setEnabled(true)
        try expect(access.connectionState == .connecting)
        try await wait { launcher.children.count == 1 }
        try expect(access.listening && access.connectionState == .connecting)
        launcher.children[0].exited()
        try expect(!access.enabled)
        try expect(access.connectionState == .notConnected && !access.listening && access.listeningPort == nil)
        try expect(!fixture.preferences.bool(forKey: "mobileAccessEnabled"))
        try expect(access.error != nil && running.busy && !running.isStopping)
        let error = access.error
        launcher.children[0].isHealthy = true
        launcher.children[0].exited()
        try expect(access.error == error && access.connectionState == .notConnected)
        let restartedLauncher = PangolinConnectorTests.Launcher()
        let restarted = RemoteAccess(credentials: credentials, preferences: fixture.preferences, assetDirectory: assets,
                                     port: 0, connector: PangolinConnector(launcher: restartedLauncher))
        restarted.attach(fixture.library)
        try expect(!restarted.enabled && !restarted.listening && restartedLauncher.validations == 0)
        running.stop(); await running.waitUntilIdle()
    }

    func connectionStatesIgnoreLateAttemptsAndTrackRecovery() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let launcher = PangolinConnectorTests.Launcher()
        let connector = PangolinConnector(launcher: launcher)
        let access = RemoteAccess(credentials: Credentials(), preferences: fixture.preferences, assetDirectory: assets,
                                  port: 0, connector: connector)
        defer { access.suspend() }
        access.attach(fixture.library)
        try expect(access.apply(siteConfiguration))
        launcher.held = true
        access.setEnabled(true)
        try await wait { launcher.continuation != nil }
        try expect(access.connectionState == .connecting && launcher.children.isEmpty)
        access.setEnabled(false)
        try expect(access.connectionState == .notConnected)
        launcher.held = false; launcher.initiallyHealthy = true
        access.setEnabled(true)
        try expect(access.connectionState == .connecting)
        try await wait { access.connectedToPangolin }
        launcher.continuation?.resume(); launcher.continuation = nil
        try await Task.sleep(for: .milliseconds(30))
        try expect(access.enabled && access.error == nil && launcher.children.count == 1)
        var replacement = siteConfiguration; replacement.siteSecret = "replacement-fake-secret"
        try expect(access.apply(replacement))
        try expect(access.connectionState == .connecting)
        try await wait { launcher.children.count == 2 && access.connectedToPangolin }
        launcher.children[0].exited()
        try await Task.sleep(for: .milliseconds(30))
        try expect(access.enabled && access.error == nil && launcher.children[0].stops == 1)
        launcher.children[1].isHealthy = false; connector.refreshHealth()
        try expect(access.connectionState == .notConnected && access.enabled)
        launcher.children[1].isHealthy = true; connector.refreshHealth()
        try expect(access.connectionState == .connected)
        access.setEnabled(false)
        try expect(access.connectionState == .notConnected && launcher.children[1].stops == 1)
        launcher.failure = true
        access.setEnabled(true)
        try await wait { !access.enabled }
        try expect(access.connectionState == .notConnected && access.error != nil && launcher.children.count == 2)
    }

    func connectorFollowsListenerConfigurationAndRelaunch() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let credentials = Credentials(), launcher = PangolinConnectorTests.Launcher()
        let access = RemoteAccess(credentials: credentials, preferences: fixture.preferences, assetDirectory: assets,
                                  port: 0, connector: PangolinConnector(launcher: launcher))
        defer { access.suspend() }
        access.attach(fixture.library)
        var configuration = PangolinConfiguration(executable: "/bin/echo", endpoint: "https://pangolin.example", siteID: "fake-site", siteSecret: "fake-secret")
        try expect(access.apply(configuration))
        try expect(launcher.validations == 0 && launcher.children.isEmpty)
        launcher.beforeLaunch = { try expect(access.listening && access.listeningPort != nil) }
        access.setEnabled(true); access.setEnabled(true)
        try await wait { launcher.children.count == 1 }
        try expect(access.error == nil && !access.connectedToPangolin)
        launcher.children[0].isHealthy = true
        try await wait { access.connectedToPangolin }
        launcher.children[0].isHealthy = false
        try await wait { !access.connectedToPangolin }
        launcher.children[0].isHealthy = true
        try await wait { access.connectedToPangolin }
        configuration.siteSecret = "replacement-fake-secret"
        credentials.failWrites = true
        try expect(!access.apply(configuration) && launcher.children[0].stops == 0)
        credentials.failWrites = false
        try expect(access.apply(configuration))
        try expect(!access.connectedToPangolin)
        try await wait { launcher.children.count == 2 }
        try expect(launcher.children[0].stops == 1 && launcher.configurations[1] == configuration)
        launcher.children[1].isHealthy = true
        try await wait { access.connectedToPangolin }
        access.suspend()
        try expect(launcher.children[1].stops == 1 && access.enabled && !access.connectedToPangolin)
        let restored = RemoteAccess(credentials: credentials, preferences: fixture.preferences, assetDirectory: assets,
                                    port: 0, connector: PangolinConnector(launcher: launcher))
        defer { restored.suspend() }
        launcher.beforeLaunch = { try expect(restored.listening) }
        restored.attach(fixture.library)
        try await wait { launcher.children.count == 3 }
        try expect(launcher.configurations[2] == configuration)
        restored.setEnabled(false)
        try expect(!restored.listening && launcher.children[2].stops == 1)
    }

    func listenerLifecycleWithoutBrowserLogin() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let credentials = Credentials()
        let access = RemoteAccess(credentials: credentials, preferences: fixture.preferences, assetDirectory: assets, port: 0,
                                  connector: PangolinConnector(launcher: PangolinConnectorTests.Launcher()))
        defer { access.setEnabled(false) }
        access.attach(fixture.library)
        try expect(!access.enabled && !access.listening && credentials.reads == 0)
        try expect(access.apply(siteConfiguration))
        access.setEnabled(true)
        try await wait { access.listening || access.error != nil }
        try expect(access.error == nil)
        let port = access.listeningPort!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func get(_ path: String, port: UInt16) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.timeoutInterval = 2
            let (body, response) = try await session.data(for: request)
            return (body, response as! HTTPURLResponse)
        }
        let (page, response) = try await get("/", port: port)
        try expect(response.statusCode == 200 && !String(decoding: page, as: UTF8.self).contains("access-key"))
        try expect(response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("frame-ancestors 'none'") == true)
        try expect(response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("manifest-src 'self'") == true)
        let (manifest, manifestResponse) = try await get("/manifest.webmanifest", port: port)
        try expect(manifestResponse.statusCode == 200 && manifestResponse.mimeType == "application/manifest+json")
        try expect((try JSONSerialization.jsonObject(with: manifest) as? [String: Any])?["display"] as? String == "standalone")
        for name in ["icon-180.png", "icon-192.png", "icon-512.png"] {
            let (icon, iconResponse) = try await get("/\(name)", port: port)
            try expect(iconResponse.statusCode == 200 && iconResponse.mimeType == "image/png")
            try expect(icon.starts(with: [0x89, 0x50, 0x4e, 0x47]))
        }
        let (_, catalog) = try await get("/api/conversations", port: port)
        try expect(catalog.statusCode == 200)
        let running = fixture.library.current
        fixture.provider.children.first!.holdOpen = true
        try running.sendRemoteMessage("Keep running when remote access stops", id: UUID())
        try await wait { fixture.provider.children.first!.pending != nil }
        access.setEnabled(true)
        try expect(access.listeningPort == port)
        access.suspend()
        try expect(!access.listening && access.enabled)
        let restored = RemoteAccess(credentials: credentials, preferences: fixture.preferences, assetDirectory: assets, port: 0,
                                  connector: PangolinConnector(launcher: PangolinConnectorTests.Launcher()))
        defer { restored.suspend() }
        restored.attach(fixture.library)
        try await wait { restored.listening || restored.error != nil }
        try expect(restored.error == nil && restored.listening)
        restored.setEnabled(false)
        access.setEnabled(false)
        try await Task.sleep(for: .milliseconds(50))
        do {
            _ = try await get("/", port: port)
            throw CheckFailure(description: "Disabled remote access still accepted a connection")
        } catch is URLError { }
        let reads = credentials.reads
        let disabled = RemoteAccess(credentials: credentials, preferences: fixture.preferences, assetDirectory: assets, port: 0,
                                  connector: PangolinConnector(launcher: PangolinConnectorTests.Launcher()))
        disabled.attach(fixture.library)
        try expect(!disabled.enabled && !disabled.listening && credentials.reads == reads)
        try expect(running.busy && !running.isStopping)
        running.stop()
        await running.waitUntilIdle()
    }

    func browsesFoldersAndCreatesWithoutChangingDesktop() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let root = fixture.root.appendingPathComponent("Projects")
        let project = root.appendingPathComponent("Phone project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try Data("instructions".utf8).write(to: project.appendingPathComponent("AGENTS.md"))
        try Data("not a folder".utf8).write(to: root.appendingPathComponent("file.txt"))
        let api = RemoteAPI(library: fixture.library, homeDirectory: root, allowedOrigins: ["https://exec.example.com"])
        var folders = RemoteHTTPRequest(method: "POST", path: "/api/folders",
            headers: ["host": "exec.example.com", "origin": "https://exec.example.com", "x-exec-request": "1", "content-type": "application/json"], body: Data("{}".utf8))
        var response = await api.handle(folders); try expect(response.status == 200)
        folders.headers["origin"] = "https://other.example.com"
        response = await api.handle(folders); try expect(response.status == 403)
        folders.headers["origin"] = "https://exec.example.com"
        response = await api.handle(folders); try expect(response.status == 200)
        let listing = try object(response)
        let entries = listing["folders"] as! [[String: Any]]
        try expect(entries.count == 1 && entries[0]["name"] as? String == "Phone project")
        try expect(listing["parent"] as? String == root.deletingLastPathComponent().resolvingSymlinksInPath().path)
        for path in ["relative", root.appendingPathComponent("missing").path, root.appendingPathComponent("file.txt").path] {
            folders.body = try JSONEncoder().encode(["path": path])
            response = await api.handle(folders); try expect(response.status == 409)
        }
        let desktop = fixture.library.current
        desktop.draft = "Keep this draft"
        fixture.library.defaultAutoApproveTools = false
        let command = RemoteAPI.Command(serverID: api.serverID, requestID: UUID(), workspacePath: project.path)
        var noOrigin = try request("/api/conversations", command: command)
        noOrigin.headers.removeValue(forKey: "origin")
        response = await api.handle(noOrigin); try expect(response.status == 403)
        response = await api.handle(try request("/api/conversations", command: command))
        try expect(response.status == 202)
        try expect(fixture.library.current === desktop && desktop.draft == "Keep this draft")
        let created = fixture.library.openConversations.first { $0.currentSessionID == command.requestID }!
        try expect(created.workspace?.root == Workspace.load(project).root)
        try expect(created.workspace?.instructions == "instructions" && created.messages.isEmpty && !created.autoApproveTools)
        try expect(created.selectedModel == fixture.library.defaultSessionModel?.id)
        let preferred = try await fixture.sessions.preferredID(identity: fixture.provider.conversationIdentity)
        try expect(preferred == fixture.ids[0])
        response = await api.handle(try request("/api/conversations", command: command)); try expect(response.status == 202)
        try expect(fixture.library.sessionList.count == 3)
        response = await api.handle(try request("/api/commands/\(command.requestID)"))
        try expect(try object(response)["accepted"] as? Bool == true)
        var changed = command; changed.workspacePath = root.path
        response = await api.handle(try request("/api/conversations", command: changed)); try expect(response.status == 409)
        let restarted = RemoteAPI(library: fixture.library, allowedOrigins: ["https://exec.example.com"])
        response = await restarted.handle(try request("/api/conversations", command: command)); try expect(response.status == 409)
        let replay = RemoteAPI.Command(serverID: restarted.serverID, requestID: command.requestID, workspacePath: project.path)
        response = await restarted.handle(try request("/api/conversations", command: replay)); try expect(response.status == 409)
        let invalid = RemoteAPI.Command(serverID: api.serverID, requestID: UUID(), workspacePath: root.appendingPathComponent("file.txt").path)
        response = await api.handle(try request("/api/conversations", command: invalid)); try expect(response.status == 409)
        try expect(fixture.library.sessionList.count == 3 && fixture.provider.children.allSatisfy { $0.inputs.isEmpty })
        api.invalidate()
        response = await api.handle(folders); try expect(response.status == 503)
    }

    func webFrontendLoadsAndSendsThroughRealHTTP() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let credentials = Credentials()
        let access = RemoteAccess(credentials: credentials, preferences: fixture.preferences, assetDirectory: assets, port: 0,
                                  homeDirectory: fixture.root,
                                  connector: PangolinConnector(launcher: PangolinConnectorTests.Launcher()))
        defer { access.setEnabled(false) }
        try expect(access.apply(siteConfiguration))
        access.attach(fixture.library); access.setEnabled(true)
        try await wait { access.listening || access.error != nil }
        try expect(access.error == nil)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: "sessionStorage.setItem('exec.key', 'obsolete'); localStorage.setItem('exec.key', 'obsolete');", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        defer { web.stopLoading(); web.loadHTMLString("", baseURL: nil) }
        web.load(URLRequest(url: URL(string: "http://127.0.0.1:\(access.listeningPort!)/")!))
        func waitJS(_ expression: String) async throws {
            for _ in 0..<600 {
                if (try? await web.evaluateJavaScript(expression)) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            let detail = (try? await web.evaluateJavaScript("document.body.innerText")) as? String ?? "No page"
            throw CheckFailure(description: "Browser check timed out: \(expression)\n\(detail)")
        }
        try await waitJS("typeof selectConversation === 'function'")
        try await waitJS("sessionStorage.getItem('exec.key') === null && localStorage.getItem('exec.key') === null")
        // A test WKWebView has no foreground window. Polling normally pauses in
        // background Safari; override visibility only in this isolated test page.
        _ = try await web.evaluateJavaScript("Object.defineProperty(document, 'hidden', { get: () => false }); void refresh();")
        try await waitJS("document.querySelectorAll('.conversation').length === 2")
        _ = try await web.evaluateJavaScript("selectConversation('\(fixture.ids[1])')")
        try await waitJS("snapshot !== null && snapshot.canSend")
        let fits = try await web.evaluateJavaScript("document.documentElement.scrollWidth <= 390") as? Bool
        try expect(fits == true)
        // Exercise the actual transcript path, not just the diff helper. Error
        // output and other tools must remain plain text even with +/- prefixes.
        let diffChecks = try await web.evaluateJavaScript(#"""
            (() => {
              const source = '--- a/file\n+++ b/file\n@@ -1,3 +1,3 @@\n-old\n+<img src=x onerror=alert(1)>\n context\n--- literal\n+++ literal\n-\n+\n\\ No newline at end of file\n+' + 'x'.repeat(500) + '\n';
              const argumentsText = JSON.stringify({ path: 'file.swift', old_text: 'old', new_text: 'new' });
              const message = (id, isDiff) => ({ id, role: 'tool', status: 'completed',
                tool: { title: 'Edit', arguments: argumentsText, output: source, isDiff } });
              renderTranscript({ ...snapshot, messages: [message('diff-test', true), message('error-test', false)] });
              const pre = document.querySelector('pre.diff');
              pre.closest('details').open = true;
              const kinds = Array.from(pre.children, node => node.className).join(',');
              const valid = pre.textContent === source && !pre.querySelector('img') &&
                kinds === 'diff-header,diff-header,diff-header,diff-removed,diff-added,diff-context,diff-removed,diff-added,diff-removed,diff-added,diff-header,diff-added,diff-context' &&
                document.querySelectorAll('pre.diff').length === 1 &&
                document.querySelectorAll('[data-id="diff-test"] .tool-content pre').length === 1 &&
                document.querySelector('[data-id="diff-test"] .tool-summary').textContent === 'file.swift' &&
                !document.querySelector('[data-id="diff-test"] .tool-content').textContent.includes(argumentsText) &&
                document.querySelector('[data-id="error-test"] .tool-content pre:first-child').textContent === argumentsText &&
                document.querySelector('[data-id="error-test"] .tool-content pre:last-child').textContent === source &&
                getComputedStyle(pre).whiteSpace === 'pre' && pre.scrollWidth > pre.clientWidth &&
                document.documentElement.scrollWidth <= 390;
              const dark = matchMedia('(prefers-color-scheme: dark)').matches;
              const added = getComputedStyle(pre.querySelector('.diff-added')).backgroundColor;
              const removed = getComputedStyle(pre.querySelector('.diff-removed')).backgroundColor;
              const colors = added === (dark ? 'rgba(48, 209, 88, 0.24)' : 'rgba(52, 199, 89, 0.24)') &&
                removed === (dark ? 'rgba(255, 66, 69, 0.22)' : 'rgba(255, 56, 60, 0.22)') &&
                getComputedStyle(pre.querySelector('.diff-header')).backgroundColor === 'rgba(0, 0, 0, 0)';
              renderTranscript(snapshot);
              return valid && colors;
            })()
            """#) as? Bool
        try expect(diffChecks == true)
        fixture.library.current.draft = "Keep desktop draft"
        _ = try await web.evaluateJavaScript("document.getElementById('message').value = '<img src=x onerror=alert(1)> **Hello**'; document.getElementById('message').dispatchEvent(new Event('input')); document.getElementById('composer').requestSubmit();")
        try await waitJS("document.getElementById('message').value === '' && document.getElementById('transcript').textContent.includes('Hello world')")
        try expect(fixture.library.current.draft == "Keep desktop draft" && fixture.library.currentSessionID == fixture.ids[0])
        let escaped = try await web.evaluateJavaScript("document.querySelector('#transcript img') === null") as? Bool
        try expect(escaped == true)
        // Simulate the response disappearing AFTER the Mac accepted the POST.
        // The frontend must keep the uncertainty and only issue a receipt GET.
        _ = try await web.evaluateJavaScript("""
            const realFetch = window.fetch;
            window.testPostCount = 0;
            window.fetch = async (url, options) => {
              const response = await realFetch(url, options);
              if (options?.method === 'POST' && url !== '/api/folders') { window.testPostCount++; throw new TypeError('Lost response'); }
              return response;
            };
            document.getElementById('message').value = 'Delivery test';
            document.getElementById('message').dispatchEvent(new Event('input'));
            document.getElementById('composer').requestSubmit();
            """)
        try await waitJS("pending !== null && !sending && !document.getElementById('uncertain').hidden")
        try await Task.sleep(for: .milliseconds(1200))
        let posts = try await web.evaluateJavaScript("window.testPostCount") as? Int
        try expect(posts == 1)
        _ = try await web.evaluateJavaScript("document.getElementById('check-delivery').click()")
        try await waitJS("pending === null && document.getElementById('message').value === ''")
        let phone = fixture.library.openConversations.first { $0.currentSessionID == fixture.ids[1] }!
        try expect(phone.messages.filter { $0.text == "Delivery test" }.count == 1)
        // The same lost-response protection applies to creation. Browsing/cancelling
        // makes no session; selecting a Mac folder makes exactly one durable session.
        _ = try await web.evaluateJavaScript("document.getElementById('back').click(); document.getElementById('new-conversation').click();")
        try await waitJS("!document.getElementById('folder-page').hidden && folderListing !== null")
        try expect(fixture.library.sessionList.count == 2)
        let pickerFits = try await web.evaluateJavaScript("document.getElementById('folder-page').scrollWidth <= 390") as? Bool
        try expect(pickerFits == true)
        _ = try await web.evaluateJavaScript("document.getElementById('folder-cancel').click()")
        try await waitJS("document.getElementById('folder-page').hidden")
        try expect(fixture.library.sessionList.count == 2)
        _ = try await web.evaluateJavaScript("document.getElementById('new-conversation').click()")
        try await waitJS("folderListing !== null")
        _ = try await web.evaluateJavaScript("document.querySelector('#folders .folder').click()")
        try await waitJS("folderListing !== null && folderListing.path.endsWith('/sessions')")
        _ = try await web.evaluateJavaScript("document.getElementById('folder-up').click()")
        try await waitJS("folderListing !== null && !folderListing.path.endsWith('/sessions')")
        _ = try await web.evaluateJavaScript("document.getElementById('folder-select').click()")
        try await waitJS("pending?.kind === 'create' && !sending && !document.getElementById('uncertain').hidden")
        try expect(fixture.library.sessionList.count == 3)
        let creationPosts = try await web.evaluateJavaScript("window.testPostCount") as? Int
        // The test transport drops only mutating commands, not read-only folder POSTs.
        try expect(creationPosts == 2)
        _ = try await web.evaluateJavaScript("document.getElementById('check-delivery').click()")
        try await waitJS("pending === null && selected && snapshot?.id === selected && snapshot.messages.length === 0")
        let newID = (try await web.evaluateJavaScript("selected")) as! String
        let created = fixture.library.openConversations.first { $0.currentSessionID?.uuidString == newID }!
        try expect(created.workspace?.root == Workspace.load(fixture.root).root)
        try expect(fixture.library.current.draft == "Keep desktop draft" && fixture.library.currentSessionID == fixture.ids[0])
        try expect(fixture.library.sessionList.count == 3)
        try await waitJS("document.getElementById('login') === null && document.getElementById('logout') === null")
        // A proxy's expired-session response is not an Exec rejection/receipt.
        // Keep delivery uncertain, disable sending, and never replay the POST.
        try await waitJS("online && snapshot?.canSend")
        _ = try await web.evaluateJavaScript("""
            window.expiredPosts = 0;
            window.fetch = async (url, options) => {
              if (options?.method === 'POST') window.expiredPosts++;
              return new Response('<html>Pangolin sign-in</html>', { status: 401, headers: { 'Content-Type': 'text/html' } });
            };
            document.getElementById('message').value = 'Expired session test';
            document.getElementById('message').dispatchEvent(new Event('input'));
            document.getElementById('composer').requestSubmit();
            """)
        try await waitJS("pending !== null && !sending && !online && document.getElementById('send').disabled")
        try await waitJS("document.getElementById('connection-error').textContent.includes('Pangolin')")
        try await Task.sleep(for: .milliseconds(1200))
        let expiredPosts = try await web.evaluateJavaScript("window.expiredPosts") as? Int
        try expect(expiredPosts == 1)
        try expect(created.messages.isEmpty)
        _ = try await web.evaluateJavaScript("window.fetch = realFetch; void refresh();")
        try await waitJS("online")
        _ = try await web.evaluateJavaScript("document.getElementById('check-delivery').click()")
        try await waitJS("pending !== null && document.getElementById('receipt-error').textContent.includes('No matching receipt')")
    }
}
