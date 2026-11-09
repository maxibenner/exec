import Foundation

@MainActor struct FetchContentTests {
    private let url = URL(string: "https://example.com/page")!
    private let call = ToolCall(id: "fetch-1", name: "fetch_content", arguments: #"{"url":"https://example.com/page"}"#)

    private actor Visits {
        var urls: [URL] = []
        func check(_ url: URL) throws { urls.append(url) }
    }

    func validatesURLsAndPublicAddresses() throws {
        for text in ["", "http://example.com", "file:///etc/passwd", "https://user:secret@example.com",
                     "https://localhost", "https://box.local", "https://example.com:8443", "https://127.0.0.1",
                     "https://[::1]", "https://[::ffff:127.0.0.1]", "https://example.com/\nspoof",
                     "https://example.com/" + String(repeating: "x", count: 2_048)] {
            try expectFailure { _ = try PublicWebURL.parse(text) }
        }
        try expect(try PublicWebURL.parse("https://example.com/page#section") == url)
        for address in ["0.0.0.0", "10.1.2.3", "127.1.2.3", "100.64.0.1", "169.254.169.254", "172.16.0.1",
                        "192.168.1.1", "192.0.2.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1",
                        "255.255.255.255", "::", "::1", "fe80::1", "fc00::1", "ff02::1", "::ffff:8.8.8.8",
                        "64:ff9b::a00:1", "2001:db8::1", "2002:7f00:1::", "not-an-address"] {
            try expect(!PublicWebURL.isPublicAddress(address))
        }
        for address in ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"] {
            try expect(PublicWebURL.isPublicAddress(address))
        }
        let session = ContentFetcher().makeSession()
        defer { session.invalidateAndCancel() }
        try expect(session.configuration.httpCookieStorage == nil && session.configuration.urlCredentialStorage == nil)
        try expect(!session.configuration.httpShouldSetCookies && session.configuration.urlCache == nil)
    }

    func fetchesTextAndRechecksRedirects() async throws {
        let html = "<html><head><style>hidden style</style><script>hidden script</script></head><body><h1>Guitars &amp; more</h1><p>Page facts &#x1F3B8;.</p><!--hidden comment--></body></html>"
        let http = HTTPStub.makeSession([
            .init(status: 302, headers: ["Location": "https://other.example.com/article"]),
            .init(headers: ["Content-Type": "text/html; charset=utf-8"], chunks: [Data(html.utf8)])
        ])
        let visits = Visits()
        let fetcher = ContentFetcher(makeSession: { http }, checkHost: { try await visits.check($0) })
        let text = try await fetcher.fetch(url)
        try expect(text.contains("Fetched URL: https://other.example.com/article"))
        try expect(text.contains("Guitars & more") && text.contains("Page facts 🎸.") && !text.contains("hidden"))
        let checked = await visits.urls
        try expect(checked.map(\.host) == ["example.com", "other.example.com"])
        try expect(HTTPStub.state.requests.count == 2)
        for request in HTTPStub.state.requests {
            try expect(request.httpMethod == "GET" && request.httpBody == nil)
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            try expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        }
        let plain = "# Plain text\n<script>literal text</script> &amp;"
        try expect(try PageText.extract(Data(plain.utf8), mime: "text/plain", charset: "utf-8") == plain)
    }

    func upgradesHTTPRedirectsWithoutDowngrading() async throws {
        for port in ["", ":80"] {
            let http = HTTPStub.makeSession([
                .init(status: 307, headers: ["Location": "http://www.example.com\(port)/article?q=a%20b#section"]),
                .init(headers: ["Content-Type": "text/plain"], chunks: [Data("Page evidence".utf8)])
            ])
            let visits = Visits()
            let text = try await ContentFetcher(makeSession: { http }, checkHost: { try await visits.check($0) }).fetch(url)
            let destination = URL(string: "https://www.example.com/article?q=a%20b")!
            try expect(HTTPStub.state.requests.map(\.url) == [url, destination])
            let checked = await visits.urls
            try expect(checked == [url, destination])
            try expect(text.contains("Fetched URL: \(destination)") && text.contains("Page evidence"))
        }
        let failed = HTTPStub.makeSession([
            .init(status: 307, headers: ["Location": "http://www.example.com/"]),
            .init(headers: ["Content-Type": "text/plain"], error: URLError(.serverCertificateUntrusted))
        ])
        do {
            _ = try await ContentFetcher(makeSession: { failed }, checkHost: { _ in }).fetch(url)
            throw CheckFailure(description: "Failed HTTPS upgrade was accepted")
        } catch let error as URLError { try expect(error.code == .serverCertificateUntrusted) }
        try expect(HTTPStub.state.requests.count == 2)
        try expect(HTTPStub.state.requests.allSatisfy { $0.url?.scheme == "https" })

        // A server may insist on HTTP even after upgrading. Keep the redirect cap;
        // do not resolve the loop by sending a plaintext request.
        let loop = HTTPStub.makeSession(Array(repeating: .init(status: 307, headers: ["Location": "http://example.com/page"]), count: 4))
        do {
            _ = try await ContentFetcher(makeSession: { loop }, checkHost: { _ in }).fetch(url)
            throw CheckFailure(description: "Redirect loop was accepted")
        } catch is ExecError {}
        try expect(HTTPStub.state.requests.count == 4)
        try expect(HTTPStub.state.requests.allSatisfy { $0.url?.scheme == "https" })
    }

    func rejectsUnsafeRedirectsAndBoundsResponses() async throws {
        for destination in ["https://127.0.0.1/private", "http://127.0.0.1/private", "http://[::1]/",
                            "http://user:secret@example.com/", "http://example.com:8080/", "http://example.com:443/",
                            "http://box.local/", "file:///etc/passwd"] {
            let http = HTTPStub.makeSession([.init(status: 302, headers: ["Location": destination])])
            do {
                _ = try await ContentFetcher(makeSession: { http }, checkHost: { _ in }).fetch(url)
                throw CheckFailure(description: "Unsafe redirect accepted")
            } catch is ExecError {}
            try expect(HTTPStub.state.requests.count == 1)
        }
        // The DNS check must run before contacting a redirect target, not just the initial host.
        let redirected = HTTPStub.makeSession([.init(status: 302, headers: ["Location": "http://private.example.com/"])])
        do {
            _ = try await ContentFetcher(makeSession: { redirected }, checkHost: { url in
                if url.host == "private.example.com" { throw ExecError("Private DNS address") }
            }).fetch(url)
            throw CheckFailure(description: "Rejected DNS address was fetched")
        } catch is ExecError {}
        try expect(HTTPStub.state.requests.count == 1)
        for reply in [HTTPStub.Reply(status: 403),
                      .init(headers: ["Content-Type": "application/pdf"]),
                      .init(headers: ["Content-Type": "text/plain", "Content-Length": "1048577"]),
                      .init(headers: ["Content-Type": "text/plain"], chunks: [Data(repeating: 65, count: 1_048_577)])] {
            let http = HTTPStub.makeSession([reply])
            do {
                _ = try await ContentFetcher(makeSession: { http }, checkHost: { _ in }).fetch(url)
                throw CheckFailure(description: "Invalid or excessive response accepted")
            } catch is ExecError {}
            try expect(HTTPStub.state.requests.count == 1)
        }
        let http = HTTPStub.makeSession([.init(headers: ["Content-Type": "text/plain"], chunks: [Data(String(repeating: "Text ", count: 10_000).utf8)])])
        let text = try await ContentFetcher(makeSession: { http }, checkHost: { _ in }).fetch(url)
        try expect(text.contains("truncated") && text.utf8.count < 25_000)
    }

    func persistsResultsWithoutWorkspaceOrSearchProvider() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        let provider = FakeProvider()
        provider.scripted = [[.toolCall(call), .completed], [.text("Read the page."), .completed]]
        let visits = Visits()
        let store = ChatStore(provider: provider, sessions: sessions, newConversation: true, fetchContent: { url in
            try await visits.check(url)
            return "Fetched URL: \(url)\nPage evidence."
        })
        store.selectedModel = "test"
        store.draft = "Read this page"
        store.send()
        await store.waitUntilIdle()
        let checked = await visits.urls
        try expect(store.workspace == nil && !provider.supportsWebSearch && store.error == nil && checked == [url])
        try expect(provider.inputs.count == 2 && provider.inputs.last?.last?.text.contains("Page evidence.") == true)
        try expect(provider.instructions.first?.contains("untrusted evidence") == true)
        let saved = try await sessions.load(id: store.currentSessionID)!
        try expect(saved.history.contains { $0.toolResult?.call.name == "fetch_content" && $0.text.contains("Page evidence.") })
        let restored = ChatStore(provider: FakeProvider(), sessions: sessions, newConversation: true, fetchContent: { _ in
            throw CheckFailure(description: "A completed fetch was replayed")
        })
        restored.openSession(store.currentSessionID!, loadModels: false)
        await restored.waitUntilIdle()
        try expect(restored.error == nil && restored.messages.contains { $0.text.contains("Page evidence.") })
        let presentation = ToolPresentation(store.messages.compactMap(\.toolResult).first!)
        try expect(presentation.title == "Fetch page" && presentation.summary == url.absoluteString)
    }

    func failuresAndCancellationNeverReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = SessionStore(directory: root)
        for cancel in [false, true] {
            let provider = FakeProvider()
            provider.scripted = [[.toolCall(call), .completed]]
            let http = HTTPStub.makeSession([cancel
                ? .init(headers: ["Content-Type": "text/plain"], chunks: [Data("Partial".utf8)], holdOpen: true)
                : .init(status: 403)])
            let fetcher = ContentFetcher(makeSession: { http }, checkHost: { _ in })
            let store = ChatStore(provider: provider, sessions: sessions, newConversation: true, fetchContent: { try await fetcher.fetch($0) })
            store.selectedModel = "test"
            store.draft = "Fetch"
            store.send()
            if cancel {
                try await wait { HTTPStub.state.heldCount == 1 }
                var checkpoint = try await sessions.load(id: store.currentSessionID)!
                try expect(checkpoint.activeCallID == call.id && checkpoint.recoverInterruptedTurn())
                try expect(checkpoint.history.last?.text == FetchContentTool.interrupted)
                store.stop()
            }
            await store.waitUntilIdle()
            try expect(provider.inputs.count == (cancel ? 1 : 2) && HTTPStub.state.requests.count == 1)
            try expect(store.error == nil)
            let result = store.messages.compactMap(\.toolResult).last!
            if cancel {
                try expect(result.text == FetchContentTool.interrupted)
            } else {
                try expect(result.text.hasPrefix("Tool error: Content fetch failed (HTTP 403)."))
                try expect(provider.inputs.last?.compactMap(\.toolResult).last == result)
                try expect(store.messages.last?.role == .assistant)
            }
            let saved = try await sessions.load(id: store.currentSessionID)!
            try expect(!saved.activeTurn && saved.activeCallID == nil)
            try expect(saved.history.compactMap(\.toolResult).last == result)
            if cancel { try await wait { HTTPStub.state.heldCount == 0 } }
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(description: "Fetch operation did not settle")
    }
}
