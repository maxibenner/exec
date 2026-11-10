import Foundation
import Observation

/// Opt-in lifecycle owned by the application, independent of any chat window.
/// No Keychain access or listening sockets are created until explicitly enabled.
@MainActor @Observable final class RemoteAccess {
    static let port: UInt16 = 9417
    static let address = "http://127.0.0.1:9417"
    private static let keyAccount = "mobile-access-key-v1"
    private(set) var enabled: Bool
    private(set) var listening = false
    private(set) var listeningPort: UInt16?
    private let bindPort: UInt16
    private(set) var error: String?
    private let credentials: any CredentialStore
    private let preferences: UserDefaults
    private let assetDirectory: URL?
    private let homeDirectory: URL
    private weak var library: ChatLibrary?
    private var server: RemoteHTTPServer?
    private var api: RemoteAPI?

    init(credentials: any CredentialStore = KeychainStore(), preferences: UserDefaults = .standard,
         assetDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("RemoteUI"),
         port: UInt16 = RemoteAccess.port,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.credentials = credentials; self.preferences = preferences; self.assetDirectory = assetDirectory
        self.homeDirectory = homeDirectory
        bindPort = port
        enabled = preferences.bool(forKey: "mobileAccessEnabled")
    }

    func attach(_ library: ChatLibrary?) {
        guard self.library !== library else { return }
        stop()
        self.library = library
        if enabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        preferences.set(enabled, forKey: "mobileAccessEnabled")
        error = nil
        if enabled { start() } else { stop() }
    }

    func accessKey() throws -> String {
        guard enabled else { throw ExecError("Enable mobile access first.") }
        if let data = try credentials.read(Self.keyAccount) {
            guard let key = String(data: data, encoding: .utf8), RemoteAccessKey.isValid(key) else {
                throw ExecError("The saved mobile access key is invalid. Reset it in Settings.")
            }
            return key
        }
        let key = RemoteAccessKey.generate()
        try credentials.write(Data(key.utf8), account: Self.keyAccount)
        return key
    }

    func resetKey() {
        do {
            let key = RemoteAccessKey.generate()
            try credentials.write(Data(key.utf8), account: Self.keyAccount)
            error = nil
            stop()
            if enabled { start() }
        } catch { self.error = error.localizedDescription }
    }

    func report(_ error: Error) { self.error = error.localizedDescription }

    private func start() {
        stop()
        guard let library else { return }
        do {
            guard let assetDirectory else { throw ExecError("The mobile frontend is missing. Rebuild Exec with scripts/build-app.sh.") }
            var assets: [String: RemoteHTTPResponse] = [:]
            for (name, type) in [("index.html", "text/html"), ("app.js", "text/javascript"), ("style.css", "text/css")] {
                let body = try Data(contentsOf: assetDirectory.appendingPathComponent(name))
                assets[name == "index.html" ? "/" : "/" + name] = RemoteHTTPResponse(contentType: type + "; charset=utf-8", body: body)
            }
            let api = RemoteAPI(library: library, key: try accessKey(), assets: assets, homeDirectory: homeDirectory)
            self.api = api
            let server = RemoteHTTPServer(handle: { [weak api] request in
                guard let api else { return .error(503, "Mobile access is disabled.") }
                return await api.handle(request)
            }, stateChanged: { [weak self] port, error in
                self?.listening = port != nil
                self?.listeningPort = port
                self?.error = error
            })
            self.server = server
            try server.start(port: bindPort)
        } catch {
            stop()
            self.error = error.localizedDescription
        }
    }

    /// Stop serving during application termination without changing the preference.
    func suspend() { stop() }

    private func stop() {
        api?.invalidate(); api = nil
        server?.stop(); server = nil
        listening = false
        listeningPort = nil
    }
}
