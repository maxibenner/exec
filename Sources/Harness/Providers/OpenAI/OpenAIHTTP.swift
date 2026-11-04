import Foundation

enum OpenAIHTTP {
    static let auth = "https://auth.openai.com"

    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }

    static func post(_ path: String, fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: auth + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        return data
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw HarnessError("Invalid HTTP response.") }
        guard (200..<300).contains(http.statusCode) else {
            // Do not expose response bodies that might contain credentials.
            throw HarnessError("OpenAI returned HTTP \(http.statusCode). Check your connection, account access, or usage limits.")
        }
    }
}
