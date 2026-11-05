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
    var activityDate: Date?
    var title: String?
    var effort: String?

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

struct SessionSummary: Codable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var customTitle: String?
    let workspace: String?
    let identity: String?
    let updatedAt: Date
    var unreadable = false

    init(id: UUID, snapshot: SessionSnapshot) {
        self.id = id
        let prompt = snapshot.messages.first { $0.role == .user }?.text ?? ""
        customTitle = snapshot.title
        title = snapshot.title ?? (prompt.isEmpty ? "New conversation" : String(prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80)))
        workspace = snapshot.workspace?.root.path
        identity = snapshot.identity
        updatedAt = snapshot.activityDate ?? Date()
    }

    init(unreadable id: UUID) {
        self.id = id
        title = "Unreadable conversation"
        workspace = nil; identity = nil; updatedAt = .distantPast; unreadable = true
    }
}

/// One snapshot per conversation, plus a small, rebuildable sidebar index. No credentials.
/// Tests inject a temporary directory; only HarnessApp chooses the user's store.
actor SessionStore {
    let directory: URL
    private let limit = 32 * 1024 * 1024
    // A fixed migration ID makes importing the old single-file save restart-safe.
    private let legacyID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private struct Catalog: Codable {
        var version = 1
        var activeID: UUID?
        var sessions: [SessionSummary] = []
    }
    private var catalog: Catalog?

    init(directory: URL) { self.directory = directory }

    static func applicationStore() throws -> SessionStore {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw HarnessError("Application Support is unavailable.")
        }
        return SessionStore(directory: base.appendingPathComponent("Harness", isDirectory: true))
    }

    func list(identity: String?) throws -> [SessionSummary] {
        try readCatalog().sessions.filter { $0.identity == identity || $0.unreadable }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }

    func preferredID(identity: String?, mostRecent: Bool = false) throws -> UUID? {
        let catalog = try readCatalog()
        let available = try list(identity: identity)
        if !mostRecent, catalog.activeID == nil { return nil }
        if !mostRecent, available.contains(where: { $0.id == catalog.activeID }) { return catalog.activeID }
        return available.first?.id
    }

    func load(id: UUID? = nil) throws -> SessionSnapshot? {
        guard let id = try id ?? readCatalog().activeID else { return nil }
        return try readSnapshot(id)
    }

    @discardableResult
    func save(_ snapshot: SessionSnapshot, id: UUID? = nil, select: Bool = true) throws -> UUID {
        var snapshot = snapshot
        var catalog = try readCatalog()
        let current = catalog.sessions.first { $0.id == catalog.activeID && $0.identity == snapshot.identity }
        let id = id ?? current?.id ?? UUID()
        if let existing = catalog.sessions.first(where: { $0.id == id }), existing.identity != snapshot.identity || existing.unreadable {
            throw HarnessError("Cannot overwrite a conversation belonging to another account or an unreadable save.")
        }
        let existing = catalog.sessions.first { $0.id == id }
        snapshot.activityDate = snapshot.activityDate ?? existing?.updatedAt ?? Date()
        snapshot.title = snapshot.title ?? existing?.customTitle
        try write(JSONEncoder().encode(snapshot), name: "\(id).json")
        catalog.sessions.removeAll { $0.id == id }
        catalog.sessions.append(SessionSummary(id: id, snapshot: snapshot))
        if select { catalog.activeID = id }
        self.catalog = catalog
        try write(JSONEncoder().encode(catalog), name: "index.json")
        if id == legacyID { try remove("session.json") }
        return id
    }

    func clearSelection() throws { try select(nil) }

    func select(_ id: UUID?) throws {
        var catalog = try readCatalog()
        guard catalog.activeID != id else { return }
        // A new conversation can be selected just before its first durable checkpoint.
        // On restart, readCatalog drops a selection whose snapshot was never written.
        catalog.activeID = id
        self.catalog = catalog
        try write(JSONEncoder().encode(catalog), name: "index.json")
    }

    func rename(id: UUID, title: String, identity: String?) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, title.utf8.count <= 1_024,
              !title.contains(where: \.isNewline) else {
            throw HarnessError("Use a single-line conversation name of up to 120 characters.")
        }
        guard var snapshot = try readSnapshot(id), snapshot.identity == identity else {
            throw HarnessError("This conversation cannot be renamed for the connected account.")
        }
        snapshot.title = title
        try save(snapshot, id: id, select: false)
    }

    func delete(id: UUID) throws {
        var catalog = try readCatalog()
        guard catalog.sessions.contains(where: { $0.id == id }) else { return }
        // Remove data first. A stale index can be rebuilt, but must not resurrect deleted data.
        if id == legacyID { try remove("session.json") }
        try remove("\(id).json")
        catalog.sessions.removeAll { $0.id == id }
        if catalog.activeID == id { catalog.activeID = nil }
        self.catalog = catalog
        try write(JSONEncoder().encode(catalog), name: "index.json")
    }

    private func readCatalog() throws -> Catalog {
        if let catalog { return catalog }
        let index = try read("index.json")
        var result = index.flatMap { try? JSONDecoder().decode(Catalog.self, from: $0) } ?? Catalog()
        guard result.version == 1 else { throw HarnessError("Saved session index format is unsupported.") }
        let names: [String]
        if FileManager.default.fileExists(atPath: directory.path) {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } else { names = [] }
        var available = Set(names.compactMap { name -> UUID? in
            guard name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(5)))
        })
        if names.contains("session.json") { available.insert(legacyID) }
        var known = Set<UUID>()
        result.sessions = result.sessions.filter { available.contains($0.id) && known.insert($0.id).inserted }
        for id in available.subtracting(known).sorted(by: { $0.uuidString < $1.uuidString }) {
            if let snapshot = try? readSnapshot(id) { result.sessions.append(SessionSummary(id: id, snapshot: snapshot)) }
            else { result.sessions.append(SessionSummary(unreadable: id)) }
        }
        if index == nil { result.activeID = result.sessions.last?.id }
        if let active = result.activeID, !available.contains(active) { result.activeID = nil }
        catalog = result
        return result
    }

    private func readSnapshot(_ id: UUID) throws -> SessionSnapshot? {
        let data: Data?
        if let current = try read("\(id).json") { data = current }
        else if id == legacyID { data = try read("session.json") }
        else { data = nil }
        guard let data else { return nil }
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        guard snapshot.version == 1,
              snapshot.workspace == nil || snapshot.workspace?.root.isFileURL == true else {
            throw HarnessError("Saved session format is unsupported.")
        }
        return snapshot
    }

    private func read(_ name: String) throws -> Data? {
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if folder < 0, errno == ENOENT { return nil }
        guard folder >= 0 else { throw HarnessError("Cannot open the saved-session directory.") }
        defer { close(folder) }
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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
        return data
    }

    private func remove(_ name: String) throws {
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if folder < 0, errno == ENOENT { return }
        guard folder >= 0 else { throw HarnessError("Cannot open the session directory for deletion.") }
        defer { close(folder) }
        guard unlinkat(folder, name, 0) == 0 || errno == ENOENT else {
            throw HarnessError("Cannot delete the saved conversation.")
        }
    }

    private func write(_ data: Data, name: String) throws {
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
        guard renameat(folder, temporary, folder, name) == 0 else {
            throw HarnessError("Cannot replace the session checkpoint.")
        }
    }
}
