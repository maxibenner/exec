import CryptoKit
import Foundation

/// Disposable display metadata, never credentials or conversation state. All disk
/// access is actor-isolated so decoding and atomic writes stay off the UI thread.
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

    private let directory: URL
    init(directory: URL) { self.directory = directory }

    static func applicationCache() -> AccountMetadataCache? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return AccountMetadataCache(directory: root.appendingPathComponent("Exec/AccountMetadata", isDirectory: true))
    }

    // Hash the scoped identity rather than putting account identifiers in filenames.
    private func file(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }

    func load(key: String) -> Snapshot {
        let url = file(for: key)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_048_576,
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Snapshot.self, from: data), saved.version == 1 else { return Snapshot() }
        return saved
    }

    func saveModels(_ models: [ChatModel], fetchedAt: Date, key: String) {
        var saved = load(key: key)
        saved.models = models
        saved.modelsFetchedAt = fetchedAt
        write(saved, key: key)
    }

    func saveUsage(_ usage: CachedAccountUsage?, key: String) {
        var saved = load(key: key)
        saved.usage = usage
        write(saved, key: key)
    }

    func remove(key: String) { try? FileManager.default.removeItem(at: file(for: key)) }

    private func write(_ snapshot: Snapshot, key: String) {
        // A cache failure must never turn a successful refresh into an app error.
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= 1_048_576 else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file(for: key), options: .atomic)
        } catch { }
    }
}
