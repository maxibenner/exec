import Foundation

struct OpenAIHTTPError: LocalizedError, Sendable {
    let status: Int
    var errorDescription: String? {
        switch status {
        case 401: "Your session was rejected. Reconnect to Codex and try again."
        case 403: "Codex denied access. Check your account and workspace permissions."
        case 429: "Codex usage or rate limit reached. Wait before trying again."
        case 500...599: "Codex is temporarily unavailable (HTTP \(status)). Try again later."
        default: "OpenAI returned HTTP \(status). The request was not retried."
        }
    }
}

enum OpenAIHTTP {
    static let auth = "https://auth.openai.com"
    // No disk cache, shared cookies or URL credential storage for bearer requests.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()

    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }

    static func post(_ path: String, fields: [String: String], session: URLSession = session) async throws -> Data {
        var request = URLRequest(url: URL(string: auth + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let (data, response) = try await session.data(for: request)
        try check(response)
        return data
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ExecError("Invalid HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            // Never surface raw response bodies: auth errors can contain secrets.
            throw OpenAIHTTPError(status: http.statusCode)
        }
    }
}
