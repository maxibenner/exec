import AppKit
import Foundation
import WebKit

@MainActor struct RemoteAccessTests {
    private final class Credentials: CredentialStore {
        var data: Data?
        var reads = 0
        var writes = 0
        func read(_ account: String) throws -> Data? { reads += 1; return data }
        func write(_ data: Data, account: String) throws { writes += 1; self.data = data }
        func delete(_ account: String) throws { data = nil }
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
    private func request(_ path: String, command: RemoteAPI.Command? = nil, key: String = "test-key") throws -> RemoteHTTPRequest {
        RemoteHTTPRequest(method: command == nil ? "GET" : "POST", path: path,
                          headers: ["host": "exec.example.com", "origin": "https://exec.example.com",
                                    "x-exec-key": key, "content-type": "application/json"],
                          body: try command.map { try JSONEncoder().encode($0) } ?? Data())
    }
    private func object(_ response: RemoteHTTPResponse) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    }

    func rejectsUnauthenticatedCrossOriginAndAmbiguousRequests() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let api = RemoteAPI(library: fixture.library, key: "test-key")
        var response = await api.handle(try request("/api/conversations", key: "wrong"))
        try expect(response.status == 401)
        var cross = try request("/api/conversations")
        cross.headers["origin"] = "https://attacker.example"
        response = await api.handle(cross); try expect(response.status == 403)
        cross.headers["origin"] = "null"
        response = await api.handle(cross); try expect(response.status == 403)
        cross.headers["origin"] = "https://exec.example.com"
        cross.headers["sec-fetch-site"] = "cross-site"
        response = await api.handle(cross); try expect(response.status == 403)
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
        response = await api.handle(try request("/api/conversations/new", command: command)); try expect(response.status == 404)
        response = await api.handle(try request("/api/conversations/\(UUID())")); try expect(response.status != 200)
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
        let api = RemoteAPI(library: library, key: "test-key")
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
        let restarted = RemoteAPI(library: library, key: "test-key")
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

    func shortKeysPreserveSavedCredentialsUntilReset() throws {
        let words = RemoteAccessKey.words
        try expect(words.count == 1295 && Set(words).count == words.count)
        try expect(words.allSatisfy { (3...5).contains($0.count) && $0.utf8.allSatisfy { (97...122).contains($0) } })
        for _ in 0..<32 {
            let key = RemoteAccessKey.generate()
            try expect(key.split(separator: "-").count == 4 && RemoteAccessKey.isValid(key))
        }
        try expect(RemoteAccessKey.isValid("apple-apple-apple-apple"))
        for invalid in ["", "apple-boat", "apple-boat-cloud", "apple-boat-cloud-drift-extra",
                        "apple--cloud-drift", "Apple-boat-cloud-drift", "apple-boat-cloud-drift-",
                        "apple boat cloud drift", "unknown-boat-cloud-drift", String(repeating: "z", count: 64)] {
            try expect(!RemoteAccessKey.isValid(invalid))
        }
        let suite = "ExecRemoteKeyTests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "mobileAccessEnabled")
        let credentials = Credentials()
        let legacy = String(repeating: "a1", count: 32)
        credentials.data = Data(legacy.utf8)
        // No library is attached: these checks never start a listener.
        let access = RemoteAccess(credentials: credentials, preferences: preferences)
        try expect(try access.accessKey() == legacy && credentials.writes == 0)
        access.resetKey()
        let key = try access.accessKey()
        try expect(key != legacy && key.split(separator: "-").count == 4 && credentials.writes == 1)
        let restored = RemoteAccess(credentials: credentials, preferences: preferences)
        try expect(try restored.accessKey() == key && credentials.writes == 1)
        credentials.data = Data("broken-key".utf8)
        try expectFailure { _ = try restored.accessKey() }
        try expect(credentials.writes == 1)
        restored.resetKey()
        try expect(restored.error == nil && RemoteAccessKey.isValid(try restored.accessKey()) && credentials.writes == 2)
    }

    func listenerLifecycleAndKeyRevocation() async throws {
        let fixture = try await Fixture.make(); defer { fixture.cleanup() }
        let credentials = Credentials()
        let access = RemoteAccess(credentials: credentials, preferences: fixture.preferences, assetDirectory: assets, port: 0)
        defer { access.setEnabled(false) }
        access.attach(fixture.library)
        try expect(!access.enabled && !access.listening && access.listeningPort == nil)
        try expect(credentials.reads == 0 && credentials.writes == 0)
        access.setEnabled(true)
        try await wait { access.listening || access.error != nil }
        try expect(access.error == nil)
        let port = access.listeningPort!
        let key = try access.accessKey()
        try expect(key.split(separator: "-").count == 4 && RemoteAccessKey.isValid(key) && credentials.writes == 1)
        try expect(try access.accessKey() == key && credentials.writes == 1)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        func get(_ path: String, key: String? = nil, port: UInt16) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.timeoutInterval = 2
            request.setValue(key, forHTTPHeaderField: "X-Exec-Key")
            let (body, response) = try await session.data(for: request)
            return (body, response as! HTTPURLResponse)
        }
        let (page, response) = try await get("/", port: port)
        try expect(response.statusCode == 200 && String(decoding: page, as: UTF8.self).contains("Remote Access"))
        try expect(response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("frame-ancestors 'none'") == true)
        let (_, unauthorized) = try await get("/api/conversations", port: port); try expect(unauthorized.statusCode == 401)
        let (_, authorized) = try await get("/api/conversations", key: key, port: port); try expect(authorized.statusCode == 200)
        let running = fixture.library.current
        fixture.provider.children.first!.holdOpen = true
        try running.sendRemoteMessage("Keep running when remote access stops", id: UUID())
        try await wait { fixture.provider.children.first!.pending != nil }
        access.resetKey()
        try await wait { access.listening || access.error != nil }
        try expect(access.error == nil && credentials.writes == 2)
        let rotatedPort = access.listeningPort!
        let (_, revoked) = try await get("/api/conversations", key: key, port: rotatedPort); try expect(revoked.statusCode == 401)
        let (_, newKey) = try await get("/api/conversations", key: access.accessKey(), port: rotatedPort); try expect(newKey.statusCode == 200)
        access.setEnabled(false)
        try expect(!access.listening && access.listeningPort == nil)
        try await Task.sleep(for: .milliseconds(50))
        do {
            _ = try await get("/", port: rotatedPort)
            throw CheckFailure(description: "Disabled remote access still accepted a connection")
        } catch is URLError { }
        let reads = credentials.reads
        let disabled = RemoteAccess(credentials: credentials, preferences: fixture.preferences, assetDirectory: assets, port: 0)
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
        let api = RemoteAPI(library: fixture.library, key: "test-key", homeDirectory: root)
        var folders = RemoteHTTPRequest(method: "POST", path: "/api/folders",
            headers: ["host": "exec.example.com", "origin": "https://exec.example.com", "x-exec-key": "wrong", "content-type": "application/json"], body: Data("{}".utf8))
        var response = await api.handle(folders); try expect(response.status == 401)
        folders.headers["x-exec-key"] = "test-key"
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
        response = await api.handle(try request("/api/conversations", command: command, key: "wrong"))
        try expect(response.status == 401 && fixture.library.sessionList.count == 2)
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
        let restarted = RemoteAPI(library: fixture.library, key: "test-key")
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
                                  homeDirectory: fixture.root)
        defer { access.setEnabled(false) }
        access.attach(fixture.library); access.setEnabled(true)
        try await wait { access.listening || access.error != nil }
        try expect(access.error == nil)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
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
        // A test WKWebView has no foreground window. Polling normally pauses in
        // background Safari; override visibility only in this isolated test page.
        _ = try await web.evaluateJavaScript("Object.defineProperty(document, 'hidden', { get: () => false }); document.getElementById('access-key').value = '\(try access.accessKey())'; document.getElementById('login-form').requestSubmit();")
        try await waitJS("document.querySelectorAll('.conversation').length === 2")
        _ = try await web.evaluateJavaScript("selectConversation('\(fixture.ids[1])')")
        try await waitJS("snapshot !== null && snapshot.canSend")
        let fits = try await web.evaluateJavaScript("document.documentElement.scrollWidth <= 390") as? Bool
        try expect(fits == true)
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
        try await waitJS("document.getElementById('folder-picker').open && folderListing !== null")
        try expect(fixture.library.sessionList.count == 2)
        let pickerFits = try await web.evaluateJavaScript("document.getElementById('folder-picker').scrollWidth <= 390") as? Bool
        try expect(pickerFits == true)
        _ = try await web.evaluateJavaScript("document.getElementById('folder-cancel').click()")
        try await waitJS("!document.getElementById('folder-picker').open")
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
        _ = try await web.evaluateJavaScript("document.getElementById('back').click(); document.getElementById('logout').click()")
        try await waitJS("!document.getElementById('login').hidden && document.getElementById('transcript').children.length === 0")
    }
}
