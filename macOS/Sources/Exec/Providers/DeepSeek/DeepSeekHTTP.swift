import Foundation

// DeepSeek never shares cookies, credentials, transport diagnostics or retries with Codex.
enum DeepSeekHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func request(_ path: String, key: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/" + path)!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        return request
    }

    static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw ExecError("Invalid DeepSeek response.") }
        guard (200..<300).contains(response.statusCode) else {
            let message: String
            switch response.statusCode {
            case 401: message = "DeepSeek rejected the API key. Update it in Settings."
            case 402: message = "Your DeepSeek balance is insufficient. Add funds to your DeepSeek account."
            case 403: message = "DeepSeek denied access to this request."
            case 429: message = "DeepSeek rate limit reached. Try again later."
            case 500...599: message = "DeepSeek is temporarily unavailable. Try again later."
            default: message = "DeepSeek returned HTTP \(response.statusCode)."
            }
            // Error bodies may echo API keys or private input. Never surface them.
            throw ExecError(message + " The request was not retried.")
        }
    }

    static func data(_ request: URLRequest, session: URLSession) async throws -> Data {
        let task = Task.detached {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            try check(response)
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1024 * 1024 else { throw ExecError("DeepSeek response exceeded the size limit.") }
                data.append(byte)
            }
            return data
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
