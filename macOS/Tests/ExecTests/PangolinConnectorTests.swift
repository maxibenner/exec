import Darwin
import Foundation

@MainActor struct PangolinConnectorTests {
    final class Child: PangolinChild {
        var stops = 0
        let exited: @MainActor () -> Void
        init(exited: @escaping @MainActor () -> Void) { self.exited = exited }
        func stop() { stops += 1 }
    }
    final class Launcher: PangolinLaunching {
        var validations = 0
        var children: [Child] = []
        var configurations: [PangolinConfiguration] = []
        var failure = false
        var held = false
        var continuation: CheckedContinuation<Void, Never>?
        var beforeLaunch: (() throws -> Void)?
        func validate(executable: String) async throws {
            validations += 1
            if held { await withCheckedContinuation { continuation = $0 } }
            if failure { throw ExecError("Unsupported test executable") }
        }
        func launch(configuration: PangolinConfiguration, exited: @escaping @MainActor () -> Void) throws -> any PangolinChild {
            try beforeLaunch?()
            configurations.append(configuration)
            let child = Child(exited: exited); children.append(child)
            return child
        }
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure(description: "Connector check did not settle")
    }

    func discoveryVersionsAndEnvironment() throws {
        let home = URL(fileURLWithPath: "/isolated/home")
        try expect(PangolinConfiguration.discover(home: home, isExecutable: { _ in false }) == nil)
        try expect(PangolinConfiguration.discover(home: home, isExecutable: { $0 == "/isolated/home/.local/bin/pangolin" }) == "/isolated/home/.local/bin/pangolin")
        try expect(PangolinConfiguration.discover(home: home, isExecutable: { $0.hasSuffix("/newt") }) == nil)
        try expect(PangolinSubprocess.supportedVersion("0.21.0\n"))
        for output in ["", "1.20.0\n", "0.20.0\n", "0.22.0\n", "0.21.0-beta\n", "newt 0.21.0\n"] {
            try expect(!PangolinSubprocess.supportedVersion(output))
        }
        let configuration = PangolinConfiguration(endpoint: "https://pangolin.example", siteID: "test-site", siteSecret: "test-secret")
        let environment = PangolinSubprocess.environment(home: home, configuration: configuration)
        try expect(environment["SITE_SECRET"] == "test-secret" && environment["SITE_ID"] == "test-site")
        try expect(environment["CONFIG_FILE"] == "/dev/null" && environment["HOME"] == home.path)
        try expect(environment["NEWT_SYSTEM_SUBSTRATE"] == "CONTAINER" && environment["SUDO_USER"] == nil)
        try expect(environment["UPDOWN_SCRIPT"] == nil && environment["SITE_PROVISIONING_KEY"] == nil)
        for invalid in ["https://user:secret@example.com", "https://example.com/path", "https://example.com?secret=test", "https://example.com#test", "https://example.com:0"] {
            var config = PangolinConfiguration(managed: false); config.resourceURL = invalid
            try expectFailure { _ = try config.validated() }
        }
    }

    func lifecycleRejectsDuplicatesLateCallbacksAndRespawns() async throws {
        let launcher = Launcher(), connector = PangolinConnector(launcher: Launcher())
        connector.stop() // Stopping a never-started component has no global effect.
        let managed = PangolinConnector(launcher: launcher)
        var errors: [String] = []; managed.failed = { errors.append($0) }
        let configuration = PangolinConfiguration()
        managed.start(configuration); managed.start(configuration)
        try await wait { launcher.children.count == 1 }
        try expect(launcher.validations == 1)
        launcher.children[0].exited()
        managed.start(configuration)
        try await Task.sleep(for: .milliseconds(30))
        try expect(launcher.children.count == 1 && errors.count == 1)
        managed.stop(); managed.start(configuration)
        try await wait { launcher.children.count == 2 }
        launcher.children[0].exited() // Old exit cannot kill/relabel the new child.
        try expect(errors.count == 1)
        managed.stop(); managed.stop()
        try expect(launcher.children[1].stops == 1)
        launcher.failure = true
        managed.start(configuration)
        try await wait { errors.count == 2 }
        managed.start(configuration)
        try await Task.sleep(for: .milliseconds(30))
        try expect(launcher.validations == 3 && launcher.children.count == 2)
        managed.stop()
        launcher.failure = false; launcher.held = true
        managed.start(configuration)
        try await wait { launcher.continuation != nil }
        managed.stop()
        launcher.continuation?.resume(); launcher.continuation = nil
        try await Task.sleep(for: .milliseconds(30))
        try expect(launcher.children.count == 2)
    }

    func realProcessesAreBoundedReapedAndIsolated() async throws {
        let root = try PangolinSubprocess.home()
        defer { try? FileManager.default.removeItem(at: root) }
        func executable(_ name: String, _ body: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        }
        let good = try executable("pangolin", "printf '0.21.0\\n'\n")
        let unsupported = try executable("newt", "printf '1.20.0\\n'\n")
        try await PangolinProcessLauncher().validate(executable: good.path)
        do {
            try await PangolinProcessLauncher().validate(executable: unsupported.path)
            throw CheckFailure(description: "Accepted an unsupported executable")
        } catch is ExecError { }
        do {
            try await PangolinProcessLauncher().validate(executable: root.appendingPathComponent("missing").path)
            throw CheckFailure(description: "Accepted a missing executable")
        } catch is ExecError { }
        // Idle quit still runs the termination hook, without a chat cancellation.
        let delegate = AppDelegate()
        var terminated = false
        delegate.stopRemoteAccess = { terminated = true }
        delegate.applicationWillTerminate(Notification(name: Notification.Name("isolated-quit")))
        try expect(terminated)

        // Quitting during a version probe must synchronously reap that probe.
        let probePIDFile = root.appendingPathComponent("probe-pid")
        let slow = try executable("slow-version", "echo $$ > '\(probePIDFile.path)'\nexec /bin/sleep 30\n")
        let launcher = PangolinProcessLauncher()
        let validation = Task { try? await launcher.validate(executable: slow.path) }
        try await wait { FileManager.default.fileExists(atPath: probePIDFile.path) }
        let probePID = Int32(try String(contentsOf: probePIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        validation.cancel(); launcher.cancelValidation()
        await validation.value
        try expect(kill(probePID, 0) == -1 && errno == ESRCH)

        // Fake foreground child ignores TERM, writes its PID, and floods output.
        // No real CLI, user's Keychain, network, or shell history is involved.
        let pidFile = root.appendingPathComponent("pid")
        let envFile = root.appendingPathComponent("environment")
        let stubborn = try executable("stubborn", """
        trap '' TERM
        echo $$ > '\(pidFile.path)'
        printf '%s\\n' "$HOME" "$CONFIG_FILE" "$SITE_SECRET" "$@" > '\(envFile.path)'
        while :; do printf 'discarded connector output\\n'; done
        """)
        let independent = Process()
        independent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        independent.arguments = ["30"]
        try independent.run()
        defer { PangolinSubprocess.stop(independent) }
        var exited = false
        let child = try PangolinProcessLauncher().launch(configuration: PangolinConfiguration(executable: stubborn.path, endpoint: "https://example.com", siteID: "fake", siteSecret: "test-secret")) { exited = true }
        try await wait { FileManager.default.fileExists(atPath: envFile.path) }
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        try expect(getpgid(pid) == pid)
        let environment = try String(contentsOf: envFile, encoding: .utf8).split(separator: "\n").map(String.init)
        try expect(environment[1] == "/dev/null" && environment[2] == "test-secret")
        try expect(Array(environment.dropFirst(3)) == ["up", "site", "--disable-ssh", "--log-level", "ERROR"])
        let start = Date()
        child.stop()
        try expect(Date().timeIntervalSince(start) < 3.5)
        try await wait { exited }
        try expect(kill(pid, 0) == -1 && errno == ESRCH)
        try expect(independent.isRunning)
        try expect(!FileManager.default.fileExists(atPath: environment[0]))
    }
}
