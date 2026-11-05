import Foundation
import CryptoKit
import Security

@MainActor final class OpenAIAuthentication {
    struct Session: Codable {
        var subject: String
        var email: String?
        var accountID: String
        var access: String
        var refresh: String
        var expires: Date
        // A lost refresh response must not cause reuse of a consumed token.
        var requiresReconnect: Bool?
    }
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Double
        let token_type: String?
    }
    private let keychain: any CredentialStore
    private let http: URLSession
    private var needsPersistence = false
    private var signingOut = false
    // Do not load, migrate or reinterpret dynamic-registration tokens as Codex tokens.
    private nonisolated static let credentialKey = "openai.codex.session"
    private var session: Session?
    private var refreshTask: Task<Session, Error>?
    var account: String? { session.map { $0.email ?? $0.subject } }
    var conversationIdentity: String? {
        session.map {
            let hash = SHA256.hash(data: Data(($0.subject + "\0" + $0.accountID).utf8))
            return "openai.codex:" + hash.map { String(format: "%02x", $0) }.joined()
        }
    }

    convenience init(keychain: any CredentialStore = KeychainStore(), http: URLSession = OpenAIHTTP.session) throws {
        try self.init(restoredData: keychain.read(Self.credentialKey), keychain: keychain, http: http)
    }

    /// Keychain may display a system permission prompt. Keep startup responsive while it waits.
    static func restored() async throws -> OpenAIAuthentication {
        let data = try await Task.detached(priority: .userInitiated) {
            try KeychainStore().read(Self.credentialKey)
        }.value
        try Task.checkCancellation()
        return try OpenAIAuthentication(restoredData: data, keychain: KeychainStore(), http: OpenAIHTTP.session)
    }

    private init(restoredData: Data?, keychain: any CredentialStore, http: URLSession) throws {
        self.keychain = keychain
        self.http = http
        if let data = restoredData {
            do { session = try JSONDecoder().decode(Session.self, from: data) }
            catch { throw HarnessError("Saved Codex credentials could not be read. Remove the openai.codex.session item from Keychain Access, then reopen Harness to sign in again.") }
        }
    }

    func connect() async throws {
        let verifier = try Self.random()
        let state = try Self.random()
        let nonce = try Self.random()
        let challenge = Self.base64(Data(SHA256.hash(data: Data(verifier.utf8))))
        let callback = OAuthCallback()
        let url = try await callback.receive(state: state, redirectURI: CodexConnection.redirectURI) {
            CodexConnection.authorizationURL(state: state, nonce: nonce, challenge: challenge)
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["error"] == nil else { throw HarnessError("Codex sign-in was declined or unavailable.") }
        guard let code = values["code"], !code.isEmpty else { throw HarnessError("Sign-in did not return an authorization code.") }
        let response = try await token(CodexConnection.exchangeFields(code: code, verifier: verifier))
        guard let idToken = response.id_token else { throw HarnessError("Sign-in did not return an identity token.") }
        let identity = try await IDTokenValidator.validate(idToken, clientID: CodexConnection.clientID, nonce: nonce)
        let accountID = try CodexConnection.accountID(in: response.access_token)
        if let identityAccount = identity.accountID, identityAccount != accountID {
            throw HarnessError("Sign-in returned inconsistent workspace credentials.")
        }
        if let session, session.subject != identity.subject || session.accountID != accountID {
            throw HarnessError("Sign out before connecting a different account or workspace.")
        }
        guard let refresh = response.refresh_token, !refresh.isEmpty else { throw HarnessError("Sign-in did not return a renewable session.") }
        let updated = Session(subject: identity.subject, email: identity.email, accountID: accountID,
                              access: response.access_token, refresh: refresh,
                              expires: Date().addingTimeInterval(response.expires_in))
        try Task.checkCancellation()
        try save(updated)
    }

    func credentials() async throws -> Session {
        try Task.checkCancellation()
        guard !signingOut else { throw HarnessError("Sign-out is in progress.") }
        if let refreshTask { return try await waitForRefresh(refreshTask) }
        if needsPersistence { try persist() }
        guard let current = session else { throw HarnessError("Connect to Codex first.") }
        guard current.requiresReconnect != true else {
            throw HarnessError("Your session needs to be renewed. Choose Reconnect from the account menu.")
        }
        if current.expires.timeIntervalSinceNow > 60 { return current }
        var pending = current
        pending.requiresReconnect = true
        // If this write fails, don't start a rotating-token exchange.
        try keychain.write(JSONEncoder().encode(pending), account: Self.credentialKey)
        session = pending
        let task = Task { @MainActor in
            let response = try await token(CodexConnection.refreshFields(current.refresh))
            guard try CodexConnection.accountID(in: response.access_token) == current.accountID else {
                throw HarnessError("Session refresh returned a different workspace. Please reconnect.")
            }
            var updated = current
            updated.access = response.access_token
            updated.refresh = response.refresh_token ?? current.refresh
            updated.expires = Date().addingTimeInterval(response.expires_in)
            updated.requiresReconnect = nil
            try save(updated)
            return updated
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await waitForRefresh(task)
    }

    private func waitForRefresh(_ task: Task<Session, Error>) async throws -> Session {
        // Rotation is shared across conversations. Finish and persist it even if one caller
        // stops, rather than cancelling other callers or losing a possibly consumed token.
        let value = try await task.value
        try Task.checkCancellation()
        return value
    }

    func disconnect() async throws {
        guard !signingOut else { return }
        signingOut = true
        defer { signingOut = false }
        // Complete a rotating refresh before revoking its latest token.
        if let refreshTask { _ = try? await refreshTask.value }
        guard let current = session else { return }
        var revocationFailed = false
        do {
            _ = try await OpenAIHTTP.post("/api/accounts/oauth/revoke", fields: [
                "token": current.refresh, "token_type_hint": "refresh_token", "client_id": CodexConnection.clientID
            ], session: http)
        } catch { revocationFailed = true }
        try keychain.delete(Self.credentialKey)
        session = nil
        needsPersistence = false
        if revocationFailed {
            throw HarnessError("Signed out locally; remote revocation was not confirmed. Review your sessions in ChatGPT Settings.")
        }
    }

    private func token(_ fields: [String: String]) async throws -> TokenResponse {
        let data = try await OpenAIHTTP.post("/oauth/token", fields: fields, session: http)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard response.expires_in.isFinite, response.expires_in > 0, !response.access_token.isEmpty,
              response.token_type == nil || response.token_type?.lowercased() == "bearer",
              response.refresh_token == nil || response.refresh_token?.isEmpty == false else {
            throw HarnessError("Codex returned an invalid token response.")
        }
        return response
    }

    private func save(_ value: Session) throws {
        // Keep newly rotated tokens in memory even if Keychain is temporarily
        // locked. Retry only persistence, never the consumed refresh token.
        session = value
        needsPersistence = true
        try persist()
    }

    private func persist() throws {
        guard let session else { return }
        do {
            try keychain.write(JSONEncoder().encode(session), account: Self.credentialKey)
            needsPersistence = false
        } catch {
            throw HarnessError("The current session could not be saved to Keychain. Unlock your keychain and try again before quitting Harness.")
        }
    }

    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HarnessError("Unable to generate secure sign-in randomness.")
        }
        return base64(Data(bytes))
    }

    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
