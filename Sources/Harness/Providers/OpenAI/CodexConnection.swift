import Foundation

// Direct Codex protocol used by Pi's openai-codex provider. These credentials
// are distinct from Sign in with ChatGPT's dynamic-registration credentials.
enum CodexConnection {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let redirectURI = "http://localhost:1455/auth/callback"
    static let baseURL = "https://chatgpt.com/backend-api/codex"
    static let originator = "swift_harness"
    static let version = "0.1.0"
    // This endpoint versions its catalog by Codex compatibility, not our app
    // release. Using Harness's 0.1.0 causes an empty (HTTP 200) catalog.
    static let catalogVersion = "0.162.1"

    static func authorizationURL(state: String, nonce: String, challenge: String) -> URL {
        var url = URLComponents(string: OpenAIHTTP.auth + "/oauth/authorize")!
        url.queryItems = [
            "client_id": clientID, "redirect_uri": redirectURI, "response_type": "code",
            "scope": "openid profile email offline_access", "state": state, "nonce": nonce,
            "code_challenge": challenge, "code_challenge_method": "S256",
            "id_token_add_organizations": "true", "codex_cli_simplified_flow": "true",
            "originator": originator
        ].map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    static func exchangeFields(code: String, verifier: String) -> [String: String] {
        ["grant_type": "authorization_code", "client_id": clientID,
         "redirect_uri": redirectURI, "code": code, "code_verifier": verifier]
    }

    static func refreshFields(_ token: String) -> [String: String] {
        ["grant_type": "refresh_token", "client_id": clientID, "refresh_token": token]
    }

    static func request(path: String, accessToken: String, accountID: String) -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue(originator, forHTTPHeaderField: "originator")
        request.setValue("SwiftHarness/\(version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func modelsRequest(accessToken: String, accountID: String) -> URLRequest {
        request(path: "/models?client_version=\(catalogVersion)", accessToken: accessToken, accountID: accountID)
    }

    static func responsesRequest(input: [[String: Any]], model: String, sessionID: String,
                                 accessToken: String, accountID: String) throws -> URLRequest {
        var request = request(path: "/responses", accessToken: accessToken, accountID: accountID)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue(sessionID, forHTTPHeaderField: "session-id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-client-request-id")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "input": input, "store": false, "stream": true,
            "instructions": "You are a helpful assistant.",
            "include": ["reasoning.encrypted_content"], "prompt_cache_key": sessionID
        ])
        return request
    }

    // Read routing metadata only from tokens received over HTTPS from OpenAI.
    // This is not local authorization: the server validates the bearer token.
    static func accountID(in accessToken: String) throws -> String {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let data = IDTokenValidator.decode(String(parts[1])),
              let claims = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String,
              !accountID.isEmpty else {
            throw HarnessError("Codex sign-in did not return an account ID.")
        }
        return accountID
    }
}
