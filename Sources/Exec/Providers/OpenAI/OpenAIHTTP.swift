import Foundation

struct OpenAIHTTPError: LocalizedError, Sendable {
    let status: Int
    var details: String? = nil
    var errorDescription: String? {
        let summary = switch status {
        case 401: "Your session was rejected. Reconnect to Codex and try again."
        case 403: "Codex denied access. Check your account and workspace permissions."
        case 429: "Codex usage or rate limit reached. Wait before trying again."
        case 500...599: "Codex is temporarily unavailable (HTTP \(status)). Try again later."
        default: "OpenAI returned HTTP \(status). The request was not retried."
        }
        return summary + (details.map { "\n" + $0 } ?? "")
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

    static func check(_ response: URLResponse, body: Data = Data(), request: URLRequest? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw ExecError("Invalid HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            // Authentication bodies may contain credentials; only expose diagnostics
            // from the resource backend, never arbitrary response fields or headers.
            var details: [String] = []
            if let url = http.url, url.host == "chatgpt.com" {
                details.append("Endpoint: " + url.path)
                if let id = http.value(forHTTPHeaderField: "x-request-id") {
                    details.append("Request ID: " + String(id.prefix(200)))
                }
                if body.count <= 16 * 1024,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    let error = (json["error"] as? [String: Any]) ?? json
                    for key in ["code", "type", "message", "param"] {
                        if let value = error[key] as? String {
                            details.append(key + ": " + value)
                        }
                    }
                    if let value = json["detail"] as? String { details.append("detail: " + value) }
                    if let value = json["error"] as? String { details.append("error: " + value) }
                } else if !body.isEmpty {
                    details.append("Server body was non-JSON or exceeded the 16 KiB diagnostic limit.")
                }
            }
            var diagnostic = details.joined(separator: "\n")
            // Remove exact credentials if the backend echoes them in a message.
            for header in ["Authorization", "ChatGPT-Account-ID"] {
                if let value = request?.value(forHTTPHeaderField: header), !value.isEmpty {
                    diagnostic = diagnostic.replacingOccurrences(of: value, with: "[redacted]")
                    if header == "Authorization", value.hasPrefix("Bearer ") {
                        let token = String(value.dropFirst(7))
                        if !token.isEmpty { diagnostic = diagnostic.replacingOccurrences(of: token, with: "[redacted]") }
                    }
                }
            }
            for pattern in [#"(?i)Bearer\s+[^\s"<>]+"#, #"sk-[A-Za-z0-9_-]+"#, #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#] {
                diagnostic = diagnostic.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
            }
            diagnostic = String(diagnostic.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }.map(String.init).joined().prefix(2400))
            throw OpenAIHTTPError(status: http.statusCode, details: diagnostic.isEmpty ? nil : diagnostic)
        }
    }
}
