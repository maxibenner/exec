import Foundation

/// The Rust service owns catalog/default persistence. Only window selection is local.
@MainActor final class SessionCatalog {
    let api: AgentAPI
    let preferences: UserDefaults
    private(set) var configuration = AgentLibraryConfiguration()
    private var write: Task<Void, Error>?
    private var writeFailure: Error?
    private var generation = 0
    init(api: AgentAPI, preferences: UserDefaults) { self.api = api; self.preferences = preferences }
    func restore() async throws {
        let generation = self.generation
        let value = try await api.get("/v1/library").decoded(AgentLibraryConfiguration.self)
        if generation == self.generation { configuration = value }
    }
    func list() async throws -> [SessionSummary] {
        let summaries = try await api.get("/v1/conversations").array.map(SessionSummary.init)
        let order = configuration.order
        return summaries.sorted {
            let a = order.firstIndex(of: $0.id) ?? Int.max, b = order.firstIndex(of: $1.id) ?? Int.max
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
    }
    var selected: UUID? { preferences.string(forKey: "agentSelectedSession").flatMap(UUID.init(uuidString:)) }
    func select(_ id: UUID?) { preferences.set(id?.uuidString, forKey: "agentSelectedSession") }
    func update(_ change: @escaping @MainActor (inout AgentLibraryConfiguration) -> Void) async throws {
        generation += 1
        let previous = write
        let next = Task { @MainActor in
            try await previous?.value
            if let writeFailure { throw writeFailure }
            var value = configuration
            change(&value)
            let before = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(configuration))
            let after = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(value))
            var patch: [String: AgentJSON] = [:]
            for field in ["automaticTitles", "defaultModel", "order"] where before[field] != after[field] { patch[field] = after[field] }
            var settings: [String: AgentJSON] = [:]
            for field in ["systemPrompt", "autoApprove", "effort", "searchModel"] where before["settings"][field] != after["settings"][field] { settings[field] = after["settings"][field] }
            if !settings.isEmpty { patch["settings"] = .object(settings) }
            if patch.isEmpty { return }
            do { configuration = try await api.request("PATCH", "/v1/library", .object(patch)).decoded(AgentLibraryConfiguration.self) }
            catch { writeFailure = error; throw error }
        }
        write = next
        try await next.value
    }
    func reorder(_ ids: [UUID]) async throws { try await update { $0.order = ids } }
    func rename(id: UUID, title: String) async throws {
        _ = try await api.request("PUT", AgentAPI.path(id, "/title"), .object(["title": .string(title)]))
    }
    func delete(id: UUID) async throws { _ = try await api.request("DELETE", AgentAPI.path(id)) }
}
