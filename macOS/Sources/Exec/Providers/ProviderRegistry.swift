import Foundation

/// Account-wide connections and model discovery. Conversation adapters below own
/// only response state; neither UI nor orchestration knows provider wire formats.
@MainActor final class ProviderRegistry {
    struct Entry {
        let id: String
        let provider: any ChatProvider
        // Preserve existing OpenAI model IDs and saved preferences.
        func modelID(_ id: String) -> String { self.id == "openai" ? id : self.id + "/" + id }
    }
    let entries: [Entry]
    let libraryIdentity: String
    private var catalogs: [String: [ChatModel]] = [:]
    private(set) var modelWarning: String?

    init(entries: [Entry], libraryIdentity: String) {
        self.entries = entries
        self.libraryIdentity = libraryIdentity
    }

    static func restored(preferences: UserDefaults = .standard) async throws -> ProviderRegistry {
        let openAI = try await OpenAIProvider.restored()
        let deepSeek = try await DeepSeekProvider.restored()
        // Seed from the previous account identity so existing sessions need no disk
        // rewrite. After that, this is a local library ID, independent of sign-in.
        let identity = preferences.string(forKey: "providerLibraryIdentity")
            ?? openAI.conversationIdentity ?? "exec.local:" + UUID().uuidString
        preferences.set(identity, forKey: "providerLibraryIdentity")
        return ProviderRegistry(entries: [.init(id: "openai", provider: openAI), .init(id: "deepseek", provider: deepSeek)],
                                libraryIdentity: identity)
    }

    func route(_ model: String) -> (entry: Entry, model: String)? {
        if let slash = model.firstIndex(of: "/") {
            let id = String(model[..<slash])
            guard let entry = entries.first(where: { $0.id == id }) else { return nil }
            return (entry, String(model[model.index(after: slash)...]))
        }
        return entries.first(where: { $0.id == "openai" }).map { ($0, model) }
    }

    func models() async throws -> [ChatModel] {
        var warnings: [String] = []
        for entry in entries {
            try Task.checkCancellation()
            guard entry.provider.account != nil else { catalogs[entry.id] = nil; continue }
            do {
                let available = try await entry.provider.models()
                try Task.checkCancellation()
                guard !available.isEmpty else { throw ExecError("No models returned.") }
                catalogs[entry.id] = available.map {
                    ChatModel(id: entry.modelID($0.id), name: $0.name,
                              contextWindow: $0.contextWindow, efforts: $0.efforts,
                              defaultEffort: $0.defaultEffort, acceptsImages: $0.acceptsImages)
                }
            } catch {
                try Task.checkCancellation()
                warnings.append("Could not refresh \(entry.provider.displayName) models. Remove and add the provider in Settings → Providers to try again.")
            }
        }
        modelWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        let available = entries.flatMap { catalogs[$0.id] ?? [] }
        if available.isEmpty, let modelWarning { throw ExecError(modelWarning) }
        return available
    }

    func connect(id: String, credential: String?) async throws {
        guard let entry = entries.first(where: { $0.id == id }) else { throw ExecError("Unknown provider.") }
        try await entry.provider.connect(id: entry.provider.connections[0].id, credential: credential)
        catalogs[id] = nil
    }
    func disconnect(id: String) async throws {
        guard let entry = entries.first(where: { $0.id == id }) else { throw ExecError("Unknown provider.") }
        defer { if entry.provider.account == nil { catalogs[id] = nil } }
        try await entry.provider.disconnect()
    }
}
