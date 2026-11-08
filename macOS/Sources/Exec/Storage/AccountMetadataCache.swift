import CryptoKit
import Darwin
import Foundation

/// Disposable display metadata, never credentials or conversation state. Disk
/// access stays off the UI thread. Account display names are stored owner-only.
actor AccountMetadataCache {
    struct Snapshot: Codable, Sendable {
        var version = 1
        var models: [ChatModel] = []
        var modelsFetchedAt: Date?
        var usage: CachedAccountUsage?

        func usableModels(at date: Date = .now) -> [ChatModel] {
            guard let modelsFetchedAt, (0...604_800).contains(date.timeIntervalSince(modelsFetchedAt)) else { return [] }
            return models
        }
    }

    private struct Startup: Codable {
        var version = 1
        let account: AccountPresentation
    }
    private let directory: URL
    private let limit = 1_048_576
    init(directory: URL) { self.directory = directory }

    static func applicationCache() -> AccountMetadataCache? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return AccountMetadataCache(directory: root.appendingPathComponent("Exec/AccountMetadata", isDirectory: true))
    }

    private func name(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    func load(key: String) -> Snapshot {
        guard let saved: Snapshot = read(name(for: key)), saved.version == 1 else { return Snapshot() }
        return saved
    }

    /// This small pointer is readable before Keychain, independently of authentication.
    /// Sessions/order/selection remain in SessionStore rather than a second transcript cache.
    func startupAccount() -> AccountPresentation? {
        guard let saved: Startup = read("startup.json"), saved.version == 1,
              !saved.account.conversationIdentity.isEmpty, !saved.account.providerName.isEmpty else { return nil }
        return saved.account
    }

    func saveStartupAccount(_ account: AccountPresentation?) {
        if let account { write(Startup(account: account), name: "startup.json") }
        else { removeFile("startup.json") }
    }

    func saveModels(_ models: [ChatModel], fetchedAt: Date, key: String) {
        var saved = load(key: key)
        saved.models = models
        saved.modelsFetchedAt = fetchedAt
        write(saved, name: name(for: key))
    }

    func saveUsage(_ usage: CachedAccountUsage?, key: String) {
        var saved = load(key: key)
        saved.usage = usage
        write(saved, name: name(for: key))
    }

    func remove(key: String) {
        removeFile(name(for: key))
        if startupAccount()?.metadataKey == key { removeFile("startup.json") }
    }

    private func read<Value: Decodable>(_ name: String) -> Value? {
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return nil }
        defer { close(folder) }
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_size <= limit,
              let data = try? file.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func removeFile(_ name: String) {
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { return }
        defer { close(folder) }
        _ = unlinkat(folder, name, 0)
    }

    private func write<Value: Encodable>(_ value: Value, name: String) {
        guard let data = try? JSONEncoder().encode(value), data.count <= limit else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard folder >= 0 else { return }
            defer { close(folder) }
            var info = stat()
            guard fstat(folder, &info) == 0, info.st_uid == geteuid(), fchmod(folder, 0o700) == 0 else { return }
            let temporary = ".metadata-\(UUID().uuidString)"
            let descriptor = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? file.close(); unlinkat(folder, temporary, 0) }
            try file.write(contentsOf: data)
            _ = renameat(folder, temporary, folder, name)
        } catch { } // A disposable cache never fails startup or a successful refresh.
    }
}
