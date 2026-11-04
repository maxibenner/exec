import Foundation
import Darwin

struct SessionSnapshot: Codable, Sendable {
    var version = 1
    var identity: String?
    var workspace: Workspace?
    var selectedModel: String
    var messages: [Message]
    var history: [Message]
    var providerState: Data?
    var activeTurn: Bool
    var activeCallID: String?

    /// Only the last completed model step can have unanswered tool calls.
    /// Missing outcomes are never inferred to be successful or re-executed.
    mutating func recoverInterruptedTurn() -> Bool {
        var interrupted = activeTurn || messages.contains { $0.status == .streaming }
        for index in messages.indices where messages[index].status == .streaming {
            messages[index].status = .interrupted
        }
        if let index = history.lastIndex(where: { $0.role == .assistant }) {
            let answered = Set(history.suffix(from: index + 1).compactMap { $0.toolResult?.call.id })
            for call in history[index].toolCalls where !answered.contains(call.id) {
                interrupted = true
                let text = call.id == activeCallID
                    ? "Interrupted before a durable result was saved. This operation may have changed files; inspect before retrying. It was not resumed."
                    : "Not executed: the previous turn was interrupted."
                let message = Message(role: .tool, text: text, toolResult: ToolResult(call: call, text: text))
                messages.append(message)
                history.append(message)
            }
        }
        activeTurn = false
        activeCallID = nil
        return interrupted
    }
}

/// One current session, atomically checkpointed off the UI actor. No credentials.
/// Tests inject a temporary directory; only HarnessApp chooses the user's store.
actor SessionStore {
    let directory: URL
    private let limit = 32 * 1024 * 1024

    init(directory: URL) { self.directory = directory }

    static func applicationStore() throws -> SessionStore {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw HarnessError("Application Support is unavailable.")
        }
        return SessionStore(directory: base.appendingPathComponent("Harness", isDirectory: true))
    }

    func load() throws -> SessionSnapshot? {
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if folder < 0, errno == ENOENT { return nil }
        guard folder >= 0 else { throw HarnessError("Cannot open the saved-session directory.") }
        defer { close(folder) }
        let descriptor = openat(folder, "session.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw HarnessError("Cannot open the saved session.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_size <= limit else {
            throw HarnessError("Saved session has an invalid type, owner, or size.")
        }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw HarnessError("Saved session exceeds 32 MiB.") }
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        guard snapshot.version == 1,
              snapshot.workspace == nil || snapshot.workspace?.root.isFileURL == true else {
            throw HarnessError("Saved session format is unsupported.")
        }
        return snapshot
    }

    func save(_ snapshot: SessionSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= limit else { throw HarnessError("Session exceeds 32 MiB. Start a new conversation.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw HarnessError("Cannot open the session directory for writing.") }
        defer { close(folder) }
        var info = stat()
        guard fstat(folder, &info) == 0, info.st_uid == geteuid(), fchmod(folder, 0o700) == 0 else {
            throw HarnessError("Cannot secure the session directory.")
        }
        let temporary = ".session-\(UUID().uuidString)"
        let descriptor = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw HarnessError("Cannot create a session checkpoint.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close(); unlinkat(folder, temporary, 0) }
        try file.write(contentsOf: data)
        try file.synchronize()
        guard renameat(folder, temporary, folder, "session.json") == 0 else {
            throw HarnessError("Cannot replace the session checkpoint.")
        }
    }
}
