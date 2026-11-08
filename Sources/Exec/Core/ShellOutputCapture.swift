import Foundation
import Darwin

/// Keeps a bounded preview in memory; only overflowing output is spooled to disk.
/// Unpublished logs (including cancelled commands) are removed on release.
final class ShellOutputCapture {
    private static let halfLimit = 16_384
    private let temporaryDirectory: URL
    private var head = Data()
    private var tail = Data()
    private var byteCount = 0
    private var logDirectory: URL?
    private var logURL: URL?
    private var log: FileHandle?
    private var logFailed = false
    private var published = false

    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectory = temporaryDirectory
    }

    deinit {
        try? log?.close()
        if !published, let logDirectory { try? FileManager.default.removeItem(at: logDirectory) }
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
            return preview + "\n[Full output log unavailable: saving failed. The command was not retried.]"
        }
        published = true
        return preview + "\n[Full captured output (\(byteCount) bytes) saved to temporary log: \(logURL.path)\n"
            + "Read it with a separate shell command (subject to approval); do not rerun the original command to recover output. The OS may remove temporary logs.]"
    }

    private func openLog() throws {
        var template = Array(temporaryDirectory.appendingPathComponent("exec-shell-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw ExecError("Cannot create shell log directory.") }
        let path = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        logDirectory = directory // mkdtemp creates a private (0700) directory.
        let url = directory.appendingPathComponent("output.log")
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ExecError("Cannot create shell log.") }
        logURL = url
        log = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func failLog() {
        logFailed = true
        try? log?.close()
        log = nil
        // Do not expose an incomplete file as a full log, or retry writes.
        if let logDirectory { try? FileManager.default.removeItem(at: logDirectory) }
    }
}
