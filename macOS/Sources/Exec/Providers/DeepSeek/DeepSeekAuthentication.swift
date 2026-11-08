import Foundation

@MainActor final class DeepSeekAuthentication {
    private struct Credential: Codable {
        let key: String
        let identity: String
    }
    nonisolated static let credentialKey = "deepseek.api-key"
    private let store: any CredentialStore
    private var credential: Credential?
    private(set) var catalog: [ChatModel] = []
    var account: String? { credential == nil ? nil : "API key connected" }
    var identity: String? { credential?.identity }

    init(store: any CredentialStore, restoredData: Data? = nil) throws {
        self.store = store
        if let restoredData {
            do { credential = try JSONDecoder().decode(Credential.self, from: restoredData) }
            catch { throw ExecError("Saved DeepSeek credentials could not be read. Remove the deepseek.api-key item in Keychain Access and reconnect.") }
        }
    }

    static func restored() async throws -> DeepSeekAuthentication {
        let data = try await Task.detached(priority: .userInitiated) {
            try KeychainStore().read(credentialKey)
        }.value
        try Task.checkCancellation()
        return try DeepSeekAuthentication(store: KeychainStore(), restoredData: data)
    }

    func key() throws -> String {
        guard let credential else { throw ExecError("Connect DeepSeek in Settings first.") }
        return credential.key
    }

    func connect(key: String, http: URLSession) async throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096,
              key.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            throw ExecError("Enter a valid DeepSeek API key.")
        }
        let models = try await loadModels(key: key, http: http)
        try Task.checkCancellation()
        let updated = Credential(key: key, identity: credential?.key == key
            ? credential!.identity : "deepseek:" + UUID().uuidString)
        // Validate and persist before replacing the working credential.
        try store.write(JSONEncoder().encode(updated), account: Self.credentialKey)
        credential = updated
        catalog = models
    }

    func disconnect() throws {
        try store.delete(Self.credentialKey)
        credential = nil
        catalog = []
    }

    func models(http: URLSession) async throws -> [ChatModel] {
        let identity = identity
        let models = try await loadModels(key: key(), http: http)
        try Task.checkCancellation()
        guard identity == self.identity else { throw CancellationError() }
        catalog = models
        return models
    }

    private func loadModels(key: String, http: URLSession) async throws -> [ChatModel] {
        struct Catalog: Decodable {
            struct Model: Decodable {
                struct Effort: Decodable { let supported_levels: [String]; let default_level: String? }
                let id: String
                let name: String?
                let context_window: Int?
                let input_modalities: [String]?
                let effort: Effort?
            }
            let data: [Model]
        }
        let data = try await DeepSeekHTTP.data(DeepSeekHTTP.request("models", key: key), session: http)
        let catalog: Catalog
        do { catalog = try JSONDecoder().decode(Catalog.self, from: data) }
        catch { throw ExecError("DeepSeek returned an invalid model catalog.") }
        var seen = Set<String>()
        let models = catalog.data.compactMap { model -> ChatModel? in
            guard !model.id.isEmpty, model.id.utf8.count <= 128, !model.id.contains("/"),
                  seen.insert(model.id).inserted else { return nil }
            var levels = Set<String>()
            let efforts = (model.effort?.supported_levels ?? []).filter {
                ["low", "high", "max"].contains($0) && levels.insert($0).inserted
            }.map { ChatEffort(id: $0, name: $0.capitalized) }
            return ChatModel(id: model.id, name: model.name ?? model.id,
                contextWindow: model.context_window.flatMap { (1...10_000_000).contains($0) ? $0 : nil },
                efforts: efforts.isEmpty ? [] : [.init(id: "none", name: "Off")] + efforts,
                defaultEffort: model.effort?.default_level,
                acceptsImages: model.input_modalities?.contains("image") ?? false)
        }
        guard !models.isEmpty else { throw ExecError("DeepSeek returned no selectable models.") }
        return models
    }
}
