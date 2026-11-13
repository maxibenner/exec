import Foundation
import Network

/// Explicit backend binding. Wildcards are translated only for the app's local connection.
struct AgentHTTPConfiguration {
    let host: String
    let port: UInt16

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        host = environment["EXEC_AGENT_HOST"] ?? "0.0.0.0"
        let ipv4 = IPv4Address(host)
        let ipv6 = IPv6Address(host)
        guard ipv4 != nil || ipv6 != nil else {
            throw ExecError("EXEC_AGENT_HOST must be a numeric network IP address.")
        }
        let mappedLoopback = ipv6.map { address in
            let bytes = Array(address.rawValue)
            return bytes.prefix(10).allSatisfy { $0 == 0 }
                && bytes[10] == 255 && bytes[11] == 255 && bytes[12] == 127
        } ?? false
        guard ipv4?.rawValue.first != 127,
              ipv6?.rawValue != IPv6Address("::1")?.rawValue, !mappedLoopback else {
            throw ExecError("Loopback-only binding is not supported.")
        }
        guard let port = UInt16(environment["EXEC_AGENT_PORT"] ?? "8765"), port > 0 else {
            throw ExecError("EXEC_AGENT_PORT must be from 1 to 65535.")
        }
        self.port = port
    }

    var clientHost: String {
        if IPv4Address(host)?.rawValue == IPv4Address("0.0.0.0")?.rawValue { return "127.0.0.1" }
        if IPv6Address(host)?.rawValue == IPv6Address("::")?.rawValue { return "::1" }
        return host
    }
}
