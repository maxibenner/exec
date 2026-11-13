import Foundation
import Network
import Security

/// One endpoint: either an owned helper or an explicitly configured external service.
/// No discovery, fallback server, shared provider credentials, or persistent client token store.
struct AgentHTTPConfiguration {
    let host: String
    let port: UInt16
    let clientHost: String
    let usesTLS: Bool
    let launchesBackend: Bool
    let token: String?
    let nativeToken: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        let insecure = try Self.flag("EXEC_AGENT_INSECURE_NO_AUTH", environment)
        let allowHTTP = try Self.flag("EXEC_AGENT_ALLOW_INSECURE_HTTP", environment)
        if let endpoint = environment["EXEC_AGENT_URL"] {
            guard environment["EXEC_AGENT_HOST"] == nil, environment["EXEC_AGENT_PORT"] == nil else {
                throw ExecError("Use EXEC_AGENT_URL for an external backend, or HOST/PORT for the bundled helper, not both.")
            }
            guard let url = URLComponents(string: endpoint),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let hostname = url.host, !hostname.isEmpty,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.isEmpty || url.path == "/",
                  let port = UInt16(exactly: url.port ?? (scheme == "https" ? 443 : 80)), port > 0 else {
                throw ExecError("EXEC_AGENT_URL must be an HTTP(S) origin without credentials, path, query or fragment.")
            }
            host = hostname.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard !host.contains("%"), !host.contains("\r"), !host.contains("\n"),
                  IPv4Address(host)?.rawValue != IPv4Address("0.0.0.0")?.rawValue,
                  IPv6Address(host)?.rawValue != IPv6Address("::")?.rawValue else {
                throw ExecError("Use a concrete backend destination, not a wildcard address.")
            }
            guard scheme == "https" || Self.isLoopback(host) || allowHTTP else {
                throw ExecError("Remote backends require HTTPS. Only set EXEC_AGENT_ALLOW_INSECURE_HTTP=1 when an encrypted tunnel or equivalent boundary protects HTTP traffic.")
            }
            self.port = port
            clientHost = host
            usesTLS = scheme == "https"
            launchesBackend = false
            token = try environment["EXEC_AGENT_TOKEN"].map(Self.validateToken)
            guard (token != nil) != insecure else {
                throw ExecError("Provide EXEC_AGENT_TOKEN, or explicitly set EXEC_AGENT_INSECURE_NO_AUTH=1 for an externally authenticated service, not both.")
            }
            nativeToken = try environment["EXEC_AGENT_NATIVE_TOKEN"].map(Self.validateToken)
        } else {
            guard !insecure else { throw ExecError("The bundled helper always requires authentication.") }
            guard environment["EXEC_AGENT_NATIVE_TOKEN"] == nil else {
                throw ExecError("EXEC_AGENT_NATIVE_TOKEN is only for external backends. The bundled helper provisions its own private native capability.")
            }
            host = environment["EXEC_AGENT_HOST"] ?? "127.0.0.1"
            guard IPv4Address(host) != nil || IPv6Address(host) != nil else {
                throw ExecError("EXEC_AGENT_HOST must be a numeric IP address.")
            }
            guard let port = UInt16(environment["EXEC_AGENT_PORT"] ?? String(HTTPAgentTransport.defaultPort)), port > 0 else {
                throw ExecError("EXEC_AGENT_PORT must be from 1 to 65535.")
            }
            self.port = port
            if IPv4Address(host)?.rawValue == IPv4Address("0.0.0.0")?.rawValue { clientHost = "127.0.0.1" }
            else if IPv6Address(host)?.rawValue == IPv6Address("::")?.rawValue { clientHost = "::1" }
            else { clientHost = host }
            usesTLS = false
            launchesBackend = true
            token = try environment["EXEC_AGENT_TOKEN"].map(Self.validateToken) ?? Self.randomToken()
            // Only the launched host adapter receives this ephemeral capability.
            nativeToken = try Self.randomToken()
        }
        guard token == nil || token != nativeToken else { throw ExecError("API and native capability credentials must be different.") }
    }

    var transport: HTTPAgentTransport {
        HTTPAgentTransport(host: clientHost, port: port, usesTLS: usesTLS, token: token, nativeToken: nativeToken)
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
    private static func flag(_ key: String, _ environment: [String: String]) throws -> Bool {
        guard let value = environment[key] else { return false }
        guard value == "0" || value == "1" else { throw ExecError("HTTP opt-out flags must be 0 or 1.") }
        return value == "1"
    }
    private static func isLoopback(_ host: String) -> Bool {
        if host.lowercased() == "localhost" || IPv4Address(host)?.rawValue.first == 127 { return true }
        guard let address = IPv6Address(host) else { return false }
        let bytes = Array(address.rawValue)
        return address.rawValue == IPv6Address("::1")?.rawValue
            || (bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255 && bytes[12] == 127)
    }
}
