import Foundation
import Observation

struct ToolAvailabilityQuery: Encodable, Equatable, Sendable {
    let names: [String]
    let conversationID: UUID?
    let model: String
    let searchModel: String?

    private enum CodingKeys: String, CodingKey { case names, conversationID, model, searchModel }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(names, forKey: .names)
        try values.encodeIfPresent(conversationID?.uuidString.lowercased(), forKey: .conversationID)
        try values.encode(model, forKey: .model)
        try values.encodeIfPresent(searchModel, forKey: .searchModel)
    }

    init(names: [String], conversationID: UUID? = nil, model: String, searchModel: String? = nil) {
        self.names = names
        self.conversationID = conversationID
        self.model = model
        self.searchModel = searchModel
    }
}

struct ToolAvailabilityStatus: Decodable, Equatable, Sendable {
    let available: Bool
    let reason: String?
}

extension AgentAPI {
    func toolAvailability(_ query: ToolAvailabilityQuery) async throws -> [String: ToolAvailabilityStatus] {
        try await send("POST", "/v1/tools/availability", body: query).decoded([String: ToolAvailabilityStatus].self)
    }
}

/// Presentation-only metadata, independent of tool selections and persisted settings.
@MainActor @Observable final class ToolAvailabilityObserver {
    private(set) var statuses: [String: ToolAvailabilityStatus] = [:]
    private var query: ToolAvailabilityQuery?
    @ObservationIgnored private var observationGeneration = UUID()
    @ObservationIgnored private var requestGeneration = UUID()

    func status(for name: String, query: ToolAvailabilityQuery) -> ToolAvailabilityStatus? {
        self.query == query ? statuses[name] : nil
    }

    /// The view owns this task's lifetime. Catalog changes replace in-flight reads;
    /// cancellation closes only this observer's subscription, never a conversation.
    func observe(query: ToolAvailabilityQuery, api: AgentAPI) async {
        let generation = UUID()
        observationGeneration = generation
        self.query = query
        statuses = [:]
        let subscription = await api.changes.subscribe(.catalog)
        var refreshTask: Task<Void, Never>?
        defer {
            subscription.close()
            refreshTask?.cancel()
            if observationGeneration == generation {
                observationGeneration = UUID()
                self.query = nil
                statuses = [:]
            }
        }
        guard !Task.isCancelled, observationGeneration == generation else { return }
        await withTaskCancellationHandler {
            refreshTask = refresh(query, api: api, generation: generation, subscription: subscription)
            for await signal in subscription.stream {
                guard !Task.isCancelled, observationGeneration == generation else { return }
                // Older change endpoints get one read per presentation/query, not polling.
                guard case .catchUp = signal else { continue }
                refreshTask?.cancel()
                refreshTask = refresh(query, api: api, generation: generation, subscription: subscription)
            }
        } onCancel: {
            subscription.close()
        }
    }

    private func refresh(_ query: ToolAvailabilityQuery, api: AgentAPI, generation: UUID,
                         subscription: AgentChangeSubscription) -> Task<Void, Never> {
        let request = UUID()
        requestGeneration = request
        // Loading and failed refreshes must not retain a stale unavailability reason.
        statuses = [:]
        return Task { [weak self] in
            do {
                try Task.checkCancellation()
                let statuses = try await api.toolAvailability(query)
                try Task.checkCancellation()
                guard let self, self.observationGeneration == generation,
                      self.requestGeneration == request, self.query == query else { return }
                self.statuses = statuses
            } catch {
                guard !Task.isCancelled, let self, self.observationGeneration == generation,
                      self.requestGeneration == request, self.query == query else { return }
                self.statuses = [:]
                // Do not repeatedly ask an older backend for an unsupported endpoint.
                if let error = error as? AgentHTTPError, error.status == 404 || error.status == 405 {
                    subscription.close()
                }
            }
        }
    }
}
