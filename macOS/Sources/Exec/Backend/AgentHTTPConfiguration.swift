import Foundation
import Security

/// Private configuration for this app's bundled helper, never an external endpoint.
struct AgentHTTPConfiguration {
    let host = "127.0.0.1"
    let port = HTTPAgentTransport.defaultPort
    let token: String
    let nativeToken: String

    init() throws {
        token = try Self.randomToken()
        nativeToken = try Self.randomToken()
    }

    var transport: HTTPAgentTransport {
        HTTPAgentTransport(host: host, port: port, token: token, nativeToken: nativeToken)
    }

    func childEnvironment(inherited: [String: String]) -> [String: String] {
        // Standalone deployment settings must not redirect or reconfigure our helper.
        var environment = inherited.filter { !$0.key.hasPrefix("EXEC_AGENT_") }
        environment.removeValue(forKey: "DEEPSEEK_API_KEY")
        environment.removeValue(forKey: "OPENAI_SESSION_JSON")
        environment["EXEC_AGENT_TOKEN"] = token
        environment["EXEC_AGENT_NATIVE_TOKEN"] = nativeToken
        return environment
    }

    static func validateToken(_ token: String) throws -> String {
        guard token.utf8.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw ExecError("HTTP secrets must be 64 hexadecimal characters (32 random bytes).")
        }
        return token
    }
    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ExecError("Could not create the backend access credential.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
