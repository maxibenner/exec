import Foundation

struct CodexConnectionTests {
    func authorizationUsesCodexFlow() throws {
        let url = CodexConnection.authorizationURL(state: "state", nonce: "nonce", challenge: "challenge")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let fields = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })
        try expect(url.host == "auth.openai.com")
        try expect(url.path == "/oauth/authorize")
        try expect(fields["client_id"] == CodexConnection.clientID)
        try expect(fields["redirect_uri"] == "http://localhost:1455/auth/callback")
        try expect(fields["state"] == "state" && fields["nonce"] == "nonce")
        try expect(fields["code_challenge"] == "challenge" && fields["code_challenge_method"] == "S256")
        try expect(fields["scope"] == "openid profile email offline_access")
        try expect(fields["originator"] == "swift_harness")
        try expect(fields["resource"] == nil && fields["agent_name_hint"] == nil)
        let exchange = CodexConnection.exchangeFields(code: "code", verifier: "verifier")
        try expect(exchange["redirect_uri"] == fields["redirect_uri"])
        try expect(exchange["client_id"] == fields["client_id"])
        try expect(exchange["code_verifier"] == "verifier" && exchange["code"] == "code")
        try expect(exchange["resource"] == nil)
        let refresh = CodexConnection.refreshFields("rotating-token")
        try expect(refresh == ["grant_type": "refresh_token", "client_id": CodexConnection.clientID, "refresh_token": "rotating-token"])
    }

    func callbackRequiresExactStateAndPath() throws {
        let redirect = CodexConnection.redirectURI
        let valid = OAuthCallback.validatedURL(target: "/auth/callback?code=code&state=expected", redirectURI: redirect, state: "expected")
        try expect(valid?.absoluteString == "http://localhost:1455/auth/callback?code=code&state=expected")
        for target in [
            "/auth/callback?code=code&state=wrong",
            "/auth/callback?code=code",
            "/auth/callback?state=expected&state=expected&code=code",
            "/auth/callback?state=expected&code=one&code=two",
            "/other?state=expected&code=code",
            "/auth/callback?state=expected&code=code#fragment",
            "https://untrusted.example/auth/callback?state=expected&code=code"
        ] {
            try expect(OAuthCallback.validatedURL(target: target, redirectURI: redirect, state: "expected") == nil)
        }
        // Auth errors must still arrive through a validated state-bound callback.
        try expect(OAuthCallback.validatedURL(target: "/auth/callback?error=access_denied&state=expected", redirectURI: redirect, state: "expected") != nil)
    }

    func catalogUsesCompatibilityVersionNotAppVersion() throws {
        let request = CodexConnection.modelsRequest(accessToken: "test-token", accountID: "test-workspace")
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        try expect(components.host == "chatgpt.com")
        try expect(components.path == "/backend-api/codex/models")
        try expect(components.queryItems == [URLQueryItem(name: "client_version", value: "0.162.1")])
        try expect(CodexConnection.catalogVersion != CodexConnection.version)
        try expect(request.value(forHTTPHeaderField: "User-Agent") == "SwiftHarness/\(CodexConnection.version)")
        try expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "test-workspace")
    }

    func requestsUseCodexEndpointAndAccountRouting() throws {
        let request = try CodexConnection.responsesRequest(
            input: [["role": "user", "content": "Hello"]], model: "test-model", sessionID: "session",
            accessToken: "test-token", accountID: "test-workspace"
        )
        try expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/responses")
        try expect(request.httpMethod == "POST")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        try expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "test-workspace")
        try expect(request.value(forHTTPHeaderField: "originator") == "swift_harness")
        try expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == "responses=experimental")
        try expect(request.value(forHTTPHeaderField: "session-id") == "session")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        try expect(body["store"] as? Bool == false && body["stream"] as? Bool == true)
        try expect(body["model"] as? String == "test-model")
        try expect((body["instructions"] as? String)?.isEmpty == false)
        try expect(body["include"] as? [String] == ["reasoning.encrypted_content"])
        try expect(body["tools"] == nil)
    }

    func readsAccountRoutingMetadata() throws {
        // Deliberately synthetic: this tests claim extraction, not token validation.
        let claims = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": "workspace"]])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try expect(try CodexConnection.accountID(in: "header.\(payload).signature") == "workspace")
        try expectFailure { _ = try CodexConnection.accountID(in: "not-a-token") }
        try expectFailure { _ = try CodexConnection.accountID(in: "header.e30.signature") }
    }

    func handlesDoneWithoutAcceptingFailure() throws {
        let done = Data(#"{"type":"response.done","response":{"status":"completed","output":[]}}"#.utf8)
        guard case .completed = try OpenAITransport.decode(done) else { throw HarnessError("Missing completion") }
        for status in ["failed", "incomplete", "cancelled", "in_progress"] {
            try expectFailure {
                _ = try OpenAITransport.decode(Data("{\"type\":\"response.done\",\"response\":{\"status\":\"\(status)\",\"output\":[]}}".utf8))
            }
        }
    }
}
