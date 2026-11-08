import Foundation
import Darwin

/// Keeps a bounded preview in memory; only overflowing output is spooled to disk.
/// The owner supplies an existing session directory; capture never recreates it.
/// Unpublished logs (including cancelled commands) are removed on release.
final class ShellOutputCapture {
    private static let halfLimit = 16_384
    private let directory: URL?
    private var head = Data()
    private var tail = Data()
    private var byteCount = 0
    private var directoryFD: Int32 = -1
    private var logURL: URL?
    private var log: FileHandle?
    private var logFailed = false
    private var published = false

    init(directory: URL? = nil) {
        self.directory = directory
    }

    deinit {
        try? log?.close()
        if !published { removeLog() }
        if directoryFD >= 0 { close(directoryFD) }
    }

    func append(_ data: Data) {
        let limit = Self.halfLimit * 2
        if byteCount <= limit, byteCount + data.count > limit {
            do {
                try openLog()
                try log?.write(contentsOf: head)
                try log?.write(contentsOf: tail)
            } catch { failLog() }
        }
        if let log {
            do { try log.write(contentsOf: data) }
            catch { failLog() }
        }
        byteCount += data.count
        let headCount = min(data.count, Self.halfLimit - head.count)
        head.append(data.prefix(headCount))
        tail.append(data.dropFirst(headCount))
        if tail.count > Self.halfLimit { tail = Data(tail.suffix(Self.halfLimit)) }
    }

    func finish() -> String {
        do { try log?.close() }
        catch { failLog() }
        log = nil
        guard byteCount > Self.halfLimit * 2 else {
            return String(decoding: head + tail, as: UTF8.self)
        }
        let omitted = byteCount - head.count - tail.count
        let preview = String(decoding: head, as: UTF8.self)
            + "\n[Output truncated: \(omitted) bytes omitted; showing first and last 16 KiB.]\n"
            + String(decoding: tail, as: UTF8.self)
        guard !logFailed, let logURL else {
            return preview + "\n[Full output log unavailable: session storage is unavailable or saving failed. The command was not retried.]"
        }
        published = true
        return preview + "\n[Full captured output (\(byteCount) bytes) saved to session log: \(logURL.path)\n"
            + "Read it with a separate shell command (subject to approval); do not rerun the original command to recover output. Deleting this session deletes its logs.]"
    }

    private func openLog() throws {
        guard let directory else { throw ExecError("Session log storage is unavailable.") }
        directoryFD = try WorkspaceFiles(root: directory).openPath(".", directory: true)
        let name = UUID().uuidString + ".log"
        let descriptor = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ExecError("Cannot create shell log.") }
        logURL = directory.appendingPathComponent(name)
        log = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func removeLog() {
        if directoryFD >= 0, let logURL { unlinkat(directoryFD, logURL.lastPathComponent, 0) }
    }

    private func failLog() {
        logFailed = true
        try? log?.close()
        log = nil
        // Do not expose an incomplete file as a full log, or retry writes.
        removeLog()
    }
}
