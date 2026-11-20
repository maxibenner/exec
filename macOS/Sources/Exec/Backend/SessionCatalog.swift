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
    @discardableResult func restore() async throws -> Bool {
        // Refresh never waits on a caller's held write. A stale read must neither
        // replace an acknowledgement nor unlock an uncertain write.
        guard write == nil else { return false }
        let generation = self.generation
        // The backend rejects GET as Busy until its pending write settles. Only a
        // successful, still-current read can clear an uncertain mutation.
        let value = try await api.get("/v1/library").decoded(AgentLibraryConfiguration.self)
        try Task.checkCancellation()
        guard generation == self.generation else { return false }
        configuration = value
        writeFailure = nil
        return true
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
        let revision = generation
        let previous = write
        let next = Task { @MainActor in
            defer { if generation == revision { write = nil } }
            // Serialize explicit changes, but do not chain a definite rejection forever.
            // Only an ambiguous write blocks later changes until an authoritative restore.
            _ = try? await previous?.value
            if let writeFailure { throw writeFailure }
            var value = configuration
            change(&value)
            let before = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(configuration))
            let after = try JSONDecoder().decode(AgentJSON.self, from: JSONEncoder().encode(value))
            var patch: [String: AgentJSON] = [:]
            for field in ["automaticTitles", "defaultModel", "defaultDisabledTools", "order"] where before[field] != after[field] { patch[field] = after[field] }
            var settings: [String: AgentJSON] = [:]
            for field in ["systemPrompt", "autoApprove", "effort", "searchModel"] where before["settings"][field] != after["settings"][field] { settings[field] = after["settings"][field] }
            if !settings.isEmpty { patch["settings"] = .object(settings) }
            if patch.isEmpty { return }
            do { configuration = try await api.request("PATCH", "/v1/library", .object(patch)).decoded(AgentLibraryConfiguration.self) }
            catch {
                // This endpoint validates before writing and reports rejection as HTTP 400.
                // Transport, storage and malformed acknowledgement failures may have committed.
                if (error as? AgentHTTPError)?.status != 400 { writeFailure = error }
                throw error
            }
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
