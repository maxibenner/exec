import Foundation
import Observation

/// Application-owned lifecycle, independent of SwiftUI updates and chat windows.
@MainActor @Observable final class RemoteAccess {
    enum ConnectionState: String {
        case notConnected = "Not connected"
        case connecting = "Connecting"
        case connected = "Connected"
    }

    static let port: UInt16 = 9417
    static let address = "http://127.0.0.1:9417"
    private(set) var enabled: Bool
    private(set) var listening = false
    private(set) var listeningPort: UInt16?
    private(set) var configuration: PangolinConfiguration?
    private(set) var error: String?
    private(set) var connectionState: ConnectionState = .notConnected
    var connectedToPangolin: Bool { connectionState == .connected }
    private let bindPort: UInt16
    private let credentials: any CredentialStore
    private let preferences: UserDefaults
    private let assetDirectory: URL?
    private let homeDirectory: URL
    private let connector: PangolinConnector
    private weak var library: ChatLibrary?
    private var server: RemoteHTTPServer?
    private var api: RemoteAPI?
    private var loaded = false
    private var generation = UUID()

    init(credentials: any CredentialStore = KeychainStore(), preferences: UserDefaults = .standard,
         assetDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("RemoteUI"),
         port: UInt16 = RemoteAccess.port,
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
         connector: PangolinConnector = PangolinConnector()) {
        self.credentials = credentials; self.preferences = preferences; self.assetDirectory = assetDirectory
        self.homeDirectory = homeDirectory; self.connector = connector
        bindPort = port
        enabled = preferences.bool(forKey: "mobileAccessEnabled")
        connector.failed = { [weak self] error in self?.fail(error) }
        connector.connectionChanged = { [weak self] connected in self?.connectionChanged(connected) }
    }

    func loadConfiguration() {
        guard !loaded else { return }
        do {
            if let data = try credentials.read(PangolinConfiguration.account) {
                configuration = try JSONDecoder().decode(PangolinConfiguration.self, from: data)
            }
            loaded = true
            // The obsolete credential is never read or used. Migration is best
            // effort and cannot damage the new atomic configuration item.
            try? credentials.delete("mobile-access-key-v1")
        } catch { self.error = "Could not read the Pangolin configuration from Keychain. Try opening Remote Access Settings again." }
    }

    @discardableResult func apply(_ draft: PangolinConfiguration) -> Bool {
        do {
            let next = try draft.validated()
            try credentials.write(JSONEncoder().encode(next), account: PangolinConfiguration.account)
            configuration = next; loaded = true; error = nil
            stop()
            if enabled { start() }
            return true
        } catch {
            self.error = error is ExecError ? error.localizedDescription : "Could not save the Pangolin configuration to Keychain. Your previous configuration is unchanged."
            return false
        }
    }

    func dismissError() { error = nil }

    func attach(_ library: ChatLibrary?) {
        guard self.library !== library else { return }
        stop(); self.library = library
        if enabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        preferences.set(enabled, forKey: "mobileAccessEnabled")
        error = nil
        if enabled { start() } else { stop() }
    }

    private func start() {
        guard enabled, server == nil, let library else { return }
        connectionState = .connecting
        let generation = self.generation
        loadConfiguration()
        guard loaded else { fail(error ?? "Could not load the Pangolin configuration."); return }
        guard let configuration else { fail("Set up Pangolin below and apply the configuration."); return }
        do {
            let configuration = try configuration.validated()
            guard let assetDirectory else { throw ExecError("The remote frontend is missing. Rebuild Exec with scripts/build-app.sh.") }
            var assets: [String: RemoteHTTPResponse] = [:]
            for (name, type) in [("index.html", "text/html"), ("app.js", "text/javascript"), ("style.css", "text/css")] {
                let body = try Data(contentsOf: assetDirectory.appendingPathComponent(name))
                assets[name == "index.html" ? "/" : "/" + name] = RemoteHTTPResponse(contentType: type + "; charset=utf-8", body: body)
            }
            let api = RemoteAPI(library: library, assets: assets, homeDirectory: homeDirectory,
                                allowedOrigins: Set([PangolinConfiguration.origin(configuration.resourceURL)].compactMap { $0 }))
            self.api = api
            let server = RemoteHTTPServer(handle: { [weak api] request in
                guard let api else { return .error(503, "Remote access is disabled.") }
                return await api.handle(request)
            }, stateChanged: { [weak self, weak api] port, error in
                guard let self, self.generation == generation else { return }
                self.listening = port != nil; self.listeningPort = port; self.error = error
                if let port {
                    api?.allowLoopback(port: port)
                    self.connector.start(configuration)
                } else { self.fail(error ?? "Could not start the remote access listener.") }
            })
            self.server = server
            try server.start(port: bindPort)
        } catch { fail(error.localizedDescription) }
    }

    private func connectionChanged(_ connected: Bool) {
        guard enabled, listening else { return }
        if connected {
            connectionState = .connected
        } else if connectionState == .connected {
            // Leave normal network recovery to Pangolin without replaying
            // application commands or claiming an unhealthy tunnel is connected.
            connectionState = .notConnected
        }
    }

    private func fail(_ message: String) {
        setEnabled(false)
        error = message
    }

    /// Stop and reap the owned connector on quit without changing the preference.
    func suspend() { stop() }

    private func stop() {
        generation = UUID()
        connectionState = .notConnected
        listening = false; listeningPort = nil
        api?.invalidate(); api = nil
        server?.stop(); server = nil
        connector.stop()
    }
}
