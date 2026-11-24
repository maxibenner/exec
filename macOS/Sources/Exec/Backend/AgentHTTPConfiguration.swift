import Foundation
import CoreFoundation
import Security

/// Validate bundle overrides before reading saved state or starting the helper.
struct AgentBundleConfiguration {
    let profileName: String
    let port: UInt16

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) throws {
        if let value = info["ExecProfileName"] {
            guard let name = value as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  name.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ExecError("ExecProfileName must be a nonempty directory name without separators, dot components or control characters.")
            }
            profileName = name
        } else {
            profileName = "Exec"
        }
        if let value = info["ExecAgentPort"] {
            // NSNumber also bridges booleans and integral reals to Int; neither is a plist integer.
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: number.objCType)),
                  let integer = value as? Int, (1...65535).contains(integer) else {
                throw ExecError("ExecAgentPort must be an integer from 1 through 65535.")
            }
            port = UInt16(integer)
        } else {
            port = HTTPAgentTransport.defaultPort
        }
    }

    func profile(in applicationSupport: URL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        applicationSupport.appendingPathComponent(profileName, isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
    }
}

/// Private configuration for this app's bundled helper, never an external endpoint.
struct AgentHTTPConfiguration {
    let host = "127.0.0.1"
    let bundleConfiguration: AgentBundleConfiguration
    var port: UInt16 { bundleConfiguration.port }
    let token: String
    let nativeToken: String

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) throws {
        bundleConfiguration = try AgentBundleConfiguration(info: info)
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
