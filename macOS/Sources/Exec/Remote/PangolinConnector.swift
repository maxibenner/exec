import Darwin
import Foundation

@MainActor protocol PangolinChild: AnyObject {
    func stop()
}

@MainActor protocol PangolinLaunching {
    func validate(executable: String) async throws
    func cancelValidation()
    func launch(configuration: PangolinConfiguration, exited: @escaping @MainActor () -> Void) throws -> any PangolinChild
}

extension PangolinLaunching {
    func cancelValidation() {}
}

/// Owns exactly one launch attempt/child. No automatic respawn after failure.
@MainActor final class PangolinConnector {
    private let launcher: any PangolinLaunching
    private var child: (any PangolinChild)?
    private var startup: Task<Void, Never>?
    private var generation = UUID()
    private var attempted = false
    var failed: (@MainActor (String) -> Void)?

    init(launcher: any PangolinLaunching = PangolinProcessLauncher()) { self.launcher = launcher }

    func start(_ configuration: PangolinConfiguration) {
        guard !attempted else { return }
        attempted = true
        let generation = self.generation
        startup = Task { [weak self] in
            guard let self else { return }
            do {
                try await launcher.validate(executable: configuration.executable)
                guard self.generation == generation, !Task.isCancelled else { return }
                child = try launcher.launch(configuration: configuration) { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.child = nil
                    self.failed?("Pangolin stopped. Check the site in Pangolin, then disable and re-enable Remote Access to reconnect.")
                }
                startup = nil
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                startup = nil
                failed?(error is ExecError ? error.localizedDescription : "Could not start Pangolin. Check the selected executable and site configuration.")
            }
        }
    }

    func stop() {
        generation = UUID()
        attempted = false
        startup?.cancel(); startup = nil
        launcher.cancelValidation()
        child?.stop(); child = nil
    }
}

@MainActor final class PangolinProcessLauncher: PangolinLaunching {
    private var probe: Process?

    func validate(executable: String) async throws {
        let process = Process()
        probe = process
        defer { if probe === process { probe = nil } }
        try await PangolinSubprocess.validate(executable: executable, process: process)
    }

    func cancelValidation() {
        // Quit must reap a version probe too, not merely cancel an async task
        // whose cleanup might otherwise run after the app has already exited.
        if let probe {
            PangolinSubprocess.stop(probe)
            if let home = probe.currentDirectoryURL { try? FileManager.default.removeItem(at: home) }
        }
        probe = nil
    }

    func launch(configuration: PangolinConfiguration, exited: @escaping @MainActor () -> Void) throws -> any PangolinChild {
        try PangolinProcess(configuration: configuration, exited: exited)
    }
}

/// Only the small version probe is captured. Connector output goes straight to
/// /dev/null: no pipe backpressure, buffering, raw diagnostics or secret logs.
private final class PangolinProbeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; data.append(bytes.prefix(max(0, 4096 - data.count))) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

enum PangolinSubprocess {
    static func supportedVersion(_ output: String) -> Bool {
        // Pin reviewed behavior, including credential persistence and in-process
        // supervision. Unknown future releases must be reviewed before adoption.
        output.split(whereSeparator: \.isNewline).first.map(String.init) == "0.21.0"
    }

    static func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Exec-Pangolin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return home
    }

    static func environment(home: URL, configuration: PangolinConfiguration? = nil) -> [String: String] {
        // Do not inherit CONFIG_FILE, SUDO_USER, proxy settings, scripts, CLI
        // account state, or any unrelated secrets from Exec's environment.
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                           "CONFIG_FILE": "/dev/null", "PANGOLIN_CLI_DISABLE_UPDATE_CHECK": "true",
                           "PANGOLIN_CLI_DISABLE_COMPANION_MODE": "true",
                           // 0.21.0 has no public site no-update flag. This reviewed
                           // upstream switch prevents modifying the user's binary.
                           "NEWT_SYSTEM_SUBSTRATE": "CONTAINER"]
        if let configuration {
            environment["PANGOLIN_ENDPOINT"] = configuration.endpoint
            environment["SITE_ID"] = configuration.siteID
            environment["SITE_SECRET"] = configuration.siteSecret
        }
        return environment
    }

    @MainActor static func validate(executable: String, process: Process) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ExecError("Pangolin CLI was not found. Install version 0.21.0 or select its executable.")
        }
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["version"]
        process.environment = environment(home: home)
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe(), output = PangolinProbeOutput()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            if let bytes = try? handle.read(upToCount: 4096), !bytes.isEmpty { output.append(bytes) }
        }
        process.standardOutput = pipe
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        try process.run()
        defer { stop(process) }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let timedOut = process.isRunning
        stop(process)
        try Task.checkCancellation()
        guard !timedOut, process.terminationStatus == 0, supportedVersion(output.text) else {
            throw ExecError("Select Pangolin CLI 0.21.0. Other versions and the standalone Newt connector are not supported.")
        }
    }

    /// Foundation Process creates a separate process group on macOS. Check that
    /// ownership before signalling the group (including any short-lived ping).
    /// Never look up, signal or adopt an independently started connector.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let ownsGroup = getpgid(pid) == pid
        if ownsGroup { _ = kill(-pid, SIGTERM) } else { process.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning {
            _ = kill(ownsGroup ? -pid : pid, SIGKILL)
        }
        // SIGKILL cannot be ignored. Foundation reaps the child before returning.
        process.waitUntilExit()
    }
}

@MainActor private final class PangolinProcess: PangolinChild {
    private let process = Process()
    private let home: URL

    init(configuration: PangolinConfiguration, exited: @escaping @MainActor () -> Void) throws {
        home = try PangolinSubprocess.home()
        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = ["up", "site", "--disable-ssh", "--log-level", "ERROR"]
        process.environment = PangolinSubprocess.environment(home: home, configuration: configuration)
        process.currentDirectoryURL = home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let home = self.home
        process.terminationHandler = { _ in
            try? FileManager.default.removeItem(at: home)
            Task { @MainActor in exited() }
        }
        do { try process.run() }
        catch { try? FileManager.default.removeItem(at: home); throw error }
    }

    func stop() {
        PangolinSubprocess.stop(process)
        try? FileManager.default.removeItem(at: home)
    }
}
