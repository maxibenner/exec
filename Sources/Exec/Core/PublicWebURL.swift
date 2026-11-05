import Foundation
import Darwin

/// Conservative public-web preflight, not a network sandbox: URLSession resolves
/// names again when connecting. HTTPS certificate validation remains enabled.
enum PublicWebURL {
    static func parse(_ text: String) throws -> URL {
        guard !text.isEmpty, text.utf8.count <= 2_048,
              text.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              var parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), !host.isEmpty, !host.contains("%") else {
            throw ExecError("Use a public HTTPS URL on port 443 without credentials, at most 2,048 bytes.")
        }
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard name.contains(".") || name.contains(":"),
              !["localhost", "local", "internal", "home", "lan", "test", "invalid", "onion"].contains(where: { name == $0 || name.hasSuffix("." + $0) }) else {
            throw ExecError("Local and private website addresses are not supported.")
        }
        if isIPAddress(name), !isPublicAddress(name) { throw ExecError("Local and private website addresses are not supported.") }
        parts.fragment = nil
        guard let url = parts.url else { throw ExecError("Invalid website URL.") }
        return url
    }

    static func checkHost(_ url: URL) async throws {
        let host = (url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        // getaddrinfo is blocking; keep it off the main actor. No HTTP request is
        // made unless every returned address passes the public-address check.
        let lookup = Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
                throw ExecError("Could not resolve the website address.")
            }
            defer { freeaddrinfo(first) }
            var entry: UnsafeMutablePointer<addrinfo>? = first
            while let current = entry {
                try Task.checkCancellation()
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &name, socklen_t(name.count),
                                  nil, 0, NI_NUMERICHOST) == 0,
                      isPublicAddress(String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)) else {
                    throw ExecError("The website resolves to a local, private, or reserved address; it was not fetched.")
                }
                entry = current.pointee.ai_next
            }
        }
        try await withTaskCancellationHandler {
            try await lookup.value
            try Task.checkCancellation()
        } onCancel: { lookup.cancel() }
    }

    private static func isIPAddress(_ address: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, address, &v4) == 1 || inet_pton(AF_INET6, address, &v6) == 1
    }

    static func isPublicAddress(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let ip = UInt32(bigEndian: v4.s_addr)
            let reserved: [(UInt32, UInt32)] = [
                (0x00000000, 8), (0x0a000000, 8), (0x64400000, 10), (0x7f000000, 8),
                (0xa9fe0000, 16), (0xac100000, 12), (0xc0000000, 24), (0xc0000200, 24),
                (0xc0586300, 24), (0xc0a80000, 16), (0xc6120000, 15), (0xc6336400, 24),
                (0xcb007100, 24), (0xe0000000, 3)
            ]
            return !reserved.contains { network, bits in ip >> (32 - bits) == network >> (32 - bits) }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        // Only global unicast; excludes loopback, link-local, ULA, multicast,
        // IPv4-mapped and translation addresses. Also exclude special-use ranges.
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            if bytes[2] < 2 || (bytes[2] == 0x0d && bytes[3] == 0xb8) { return false }
        }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false }
        if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 { return false }
        return true
    }
}
