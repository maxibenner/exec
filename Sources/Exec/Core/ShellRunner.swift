import Foundation
import Darwin

/// Approved commands run with normal user privileges, NOT in a sandbox.
/// A new process group lets Stop/timeout terminate ordinary child processes too.
enum ShellRunner {
    static func run(_ command: String, in directory: URL, timeout: Duration = .seconds(30)) async throws -> String {
        try Task.checkCancellation()
        var pipeFD: [Int32] = [0, 0]
        guard pipe(&pipeFD) == 0 else { throw ExecError("Cannot create command output pipe.") }
        defer { close(pipeFD[0]); close(pipeFD[1]) }
        guard fcntl(pipeFD[0], F_SETFL, O_NONBLOCK) == 0 else { throw ExecError("Cannot configure command output.") }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ExecError("Cannot prepare command.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw ExecError("Cannot prepare command process group.") }
        defer { posix_spawnattr_destroy(&attributes) }
        let changedDirectory: Int32
        if #available(macOS 26, *) {
            changedDirectory = posix_spawn_file_actions_addchdir(&actions, directory.path)
        } else {
            changedDirectory = posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        }
        let setup = [
            changedDirectory,
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, pipeFD[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, pipeFD[1], STDERR_FILENO),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        ]
        guard setup.allSatisfy({ $0 == 0 }) else { throw ExecError("Cannot set command working directory or output.") }
        // Do not inherit API tokens, agent variables, shell startup hooks, etc.
        let environment = [
            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME=\(FileManager.default.homeDirectoryForCurrentUser.path)",
            "LANG=en_US.UTF-8", "TMPDIR=\(NSTemporaryDirectory())"
        ]
        let argv = ["/bin/bash", "--noprofile", "--norc", "-c", command].map { (value: String) in value.withCString { strdup($0) } } + [nil]
        let env = environment.map { value in value.withCString { strdup($0) } } + [nil]
        defer { for value in argv + env { free(value) } }
        var pid: pid_t = 0
        let launched = argv.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { variables in
                posix_spawn(&pid, "/bin/bash", &actions, &attributes, args.baseAddress!, variables.baseAddress!)
            }
        }
        guard launched == 0 else { throw ExecError("Could not start command (system error \(launched)).") }
        var reaped = false
        defer {
            // Also stop background jobs left behind by a normally exited shell.
            kill(-pid, SIGKILL)
            if !reaped {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            }
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var output = Data()
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() {
            // Bound each pass so continuous output cannot starve cancellation.
            for _ in 0..<16 {
                let count = Darwin.read(pipeFD[0], &buffer, buffer.count)
                if count <= 0 { break }
                let available = max(0, 32_768 - output.count)
                output.append(contentsOf: buffer.prefix(min(count, available)))
                if count > available { truncated = true }
            }
        }
        while true {
            drain()
            try Task.checkCancellation()
            if ContinuousClock.now >= deadline {
                return "Command timed out; termination requested for its process group. It may have changed files.\n" + String(decoding: output, as: UTF8.self) + (truncated ? "\n[Output truncated at 32 KiB.]" : "")
            }
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                reaped = true
                drain()
                let exit = status & 0x7f == 0 ? "Exit code: \((status >> 8) & 0xff)" : "Terminated by signal: \(status & 0x7f)"
                return exit + "\n" + String(decoding: output, as: UTF8.self) + (truncated ? "\n[Output truncated at 32 KiB.]" : "")
            }
            if waited == -1 && errno != EINTR { throw ExecError("Could not collect command status; it may have changed files.") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
