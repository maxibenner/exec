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
    private static let credentialProvidersKey = "credentialProviderIDs"
    private let preferences: UserDefaults?

    init(entries: [Entry], libraryIdentity: String, preferences: UserDefaults? = nil) {
        self.entries = entries
        self.libraryIdentity = libraryIdentity
        self.preferences = preferences
    }

    /// The local library survives provider sign-out and does not require Keychain.
    /// An empty account name deliberately carries no claimed connection status.
    static func localPresentation(preferences: UserDefaults = .standard) -> AccountPresentation? {
        guard let identity = preferences.string(forKey: "providerLibraryIdentity"), !identity.isEmpty else { return nil }
        return AccountPresentation(providerName: "Providers", connectionTitle: "Connect a provider in Settings",
                                   accountName: "", conversationIdentity: identity)
    }

    static func restored(preferences: UserDefaults = .standard, hasLegacyAccount: Bool = false,
                         loadProvider: @MainActor (String, Bool) async throws -> any ChatProvider = loadProvider) async throws -> ProviderRegistry {
        // This cache contains only provider IDs, never credentials. An explicit empty
        // list distinguishes a new/unconnected install from one predating the cache.
        let selected = preferences.stringArray(forKey: credentialProvidersKey)
            ?? ((hasLegacyAccount || preferences.string(forKey: "providerLibraryIdentity") != nil)
                ? ["openai", "deepseek"] : [])
        let openAI = try await loadProvider("openai", selected.contains("openai"))
        let deepSeek = try await loadProvider("deepseek", selected.contains("deepseek"))
        try Task.checkCancellation()
        // Seed from the previous account identity so existing sessions need no disk
        // rewrite. After that, this is a local library ID, independent of sign-in.
        let identity = preferences.string(forKey: "providerLibraryIdentity")
            ?? openAI.conversationIdentity ?? "exec.local:" + UUID().uuidString
        let entries: [Entry] = [.init(id: "openai", provider: openAI), .init(id: "deepseek", provider: deepSeek)]
        // Commit the cache only after all reads succeed; denied access is not sign-out.
        preferences.set(entries.filter { $0.provider.account != nil }.map(\.id), forKey: credentialProvidersKey)
        preferences.set(identity, forKey: "providerLibraryIdentity")
        return ProviderRegistry(entries: entries, libraryIdentity: identity, preferences: preferences)
    }

    private static func loadProvider(_ id: String, _ loadCredentials: Bool) async throws -> any ChatProvider {
        switch id {
        case "openai": return try await OpenAIProvider.restored(loadCredentials: loadCredentials)
        case "deepseek": return try await DeepSeekProvider.restored(loadCredentials: loadCredentials)
        default: throw ExecError("Unknown provider.")
        }
    }

    private func rememberCredentials(for id: String, present: Bool) {
        guard let preferences else { return }
        var selected = Set(preferences.stringArray(forKey: Self.credentialProvidersKey) ?? [])
        if present { selected.insert(id) } else { selected.remove(id) }
        preferences.set(selected.sorted(), forKey: Self.credentialProvidersKey)
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
        // Record intent before authentication can persist credentials, including if
        // the app quits between the Keychain write and completion of this operation.
        rememberCredentials(for: id, present: true)
        try await entry.provider.connect(id: entry.provider.connections[0].id, credential: credential)
        catalogs[id] = nil
    }
    func disconnect(id: String) async throws {
        guard let entry = entries.first(where: { $0.id == id }) else { throw ExecError("Unknown provider.") }
        defer {
            if entry.provider.account == nil {
                catalogs[id] = nil
                rememberCredentials(for: id, present: false)
            }
        }
        try await entry.provider.disconnect()
    }
}
