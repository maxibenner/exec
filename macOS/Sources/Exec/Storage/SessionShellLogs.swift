import Foundation
import Darwin

/// Session IDs, never transcript paths, determine ownership. Operations are
/// descriptor-relative and do not follow symlinks outside the managed store.
struct SessionShellLogs {
    let directory: URL

    func prepare(id: UUID) throws -> URL {
        let root = try WorkspaceFiles(root: directory).openPath(".", directory: true)
        defer { close(root) }
        let name = directoryName(id)
        guard mkdirat(root, name, 0o700) == 0 || errno == EEXIST else {
            throw ExecError("Cannot create session shell log directory.")
        }
        let logs = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard logs >= 0 else { throw ExecError("Cannot open session shell log directory.") }
        close(logs)
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    func remove(id: UUID) throws {
        let root = try WorkspaceFiles(root: directory).openPath(".", directory: true)
        defer { close(root) }
        let name = directoryName(id)
        let logs = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if logs < 0, errno == ENOENT { return }
        guard logs >= 0 else { throw ExecError("Cannot open session shell logs for deletion.") }
        guard let stream = fdopendir(logs) else {
            close(logs)
            throw ExecError("Cannot list session shell logs for deletion.")
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw ExecError("Cannot list session shell logs for deletion.") }
                break
            }
            let file = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if file == "." || file == ".." { continue }
            // Logs are flat files. Unlink symlinks themselves, never their targets;
            // unexpected subdirectories fail deletion instead of recursing into them.
            guard unlinkat(logs, file, 0) == 0 || errno == ENOENT else {
                throw ExecError("Cannot delete a session shell log.")
            }
        }
        guard unlinkat(root, name, AT_REMOVEDIR) == 0 || errno == ENOENT else {
            throw ExecError("Cannot delete the session shell log directory.")
        }
    }

    private func directoryName(_ id: UUID) -> String { "\(id.uuidString).shell-logs" }
}
