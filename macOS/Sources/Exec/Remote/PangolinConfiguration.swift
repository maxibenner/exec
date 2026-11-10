import Foundation

/// One atomic Keychain value: a failed save cannot mix old and new credentials.
struct PangolinConfiguration: Codable, Equatable, Sendable {
    var executable = ""
    var endpoint = ""
    var siteID = ""
    var siteSecret = ""
    var resourceURL = ""

    static let account = "remote-pangolin-configuration-v1"

    func validated() throws -> Self {
        var value = self
        value.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        value.siteID = siteID.trimmingCharacters(in: .whitespacesAndNewlines)
        value.resourceURL = resourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.resourceURL.isEmpty {
            guard Self.origin(value.resourceURL) != nil else {
                throw ExecError("Enter the resource’s HTTP or HTTPS URL without a path, credentials, or query.")
            }
        }
        guard let origin = Self.origin(value.endpoint), origin.hasPrefix("https://") else {
            throw ExecError("Enter the Pangolin dashboard’s HTTPS URL without a path, credentials, or query.")
        }
        guard !value.siteID.isEmpty, !siteSecret.isEmpty,
              !value.siteID.contains(where: \.isWhitespace), !value.siteID.contains("\0"),
              !siteSecret.contains(where: \.isWhitespace), !siteSecret.contains("\0") else {
            throw ExecError("Enter the Site ID and Site Secret from Pangolin.")
        }
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw ExecError("Install Pangolin CLI 0.21.0, then select its executable.")
        }
        return value
    }

    static func origin(_ text: String) -> String? {
        guard let url = URLComponents(string: text), let scheme = url.scheme,
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.port.map({ (1...65535).contains($0) }) ?? true,
              host.utf8.allSatisfy({ (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }) else { return nil }
        let port = url.port.flatMap { ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? nil : $0 }
        return "\(scheme)://\(host.lowercased())" + (port.map { ":\($0)" } ?? "")
    }

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        // Finder-launched apps do not inherit an interactive shell PATH.
        ["/opt/homebrew/bin/pangolin", "/usr/local/bin/pangolin",
         home.appendingPathComponent(".local/bin/pangolin").path,
         home.appendingPathComponent("bin/pangolin").path].first(where: isExecutable)
    }
}
