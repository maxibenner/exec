import AppKit
import Observation

/// Account operations are service requests, never provider HTTP/authentication in Swift.
@MainActor @Observable final class AgentAccounts: ChatProvider {
    let api: AgentAPI
    private(set) var connections: [ProviderConnection] = []
    private var usableProviders: Set<String> = []
    private var attemptID: String?
    private var cancellationRequested = false
    private var cancellationSent = false
    init(api: AgentAPI) { self.api = api }
    var account: String? { connections.first { $0.account != nil }?.account }
    func providerID(for model: String) -> String? { model.split(separator: "/", maxSplits: 1).first.map(String.init) }
    func isModelAvailable(_ model: String) -> Bool { providerID(for: model).map(usableProviders.contains) == true }
    func refreshConnections() async throws {
        let statuses = try await api.get("/v1/providers").array
        usableProviders = Set(statuses.filter { $0["connected"].bool && !$0["blocked"].bool }.compactMap { $0["id"].string })
        connections = statuses.compactMap { value in
            guard let id = value["id"].string, let name = value["name"].string else { return nil }
            return ProviderConnection(id: id, name: name, account: value["connected"].bool ? (value["email"].string ?? "") : nil,
                authentication: id == "deepseek" ? .apiKey : .browser,
                webSearch: id == "deepseek" ? .service("DeepSeek") : .model,
                supportsImageGeneration: id == "openai", balanceIdentity: id == "deepseek" && value["connected"].bool ? id : nil)
        }
    }
    func models() async throws -> [ChatModel] {
        try await api.get("/v1/models").array.map { value in
            guard let id = value["id"].string, let name = value["name"].string else { throw ExecError("The backend returned an invalid model.") }
            return ChatModel(id: id, name: name, contextWindow: value["contextWindow"].number.map(Int.init),
                efforts: try value["efforts"].array.map { try $0.decoded(ChatEffort.self) },
                defaultEffort: value["defaultEffort"].string, acceptsImages: value["acceptsImages"] == .null ? nil : value["acceptsImages"].bool)
        }
    }
    func connect(id: String, credential: String?) async throws {
        cancellationRequested = false
        cancellationSent = false
        if id == "deepseek" {
            _ = try await api.request("PUT", "/v1/providers/deepseek", .object(["apiKey": .string(credential ?? "")]))
        } else if id == "openai" {
            let response = try await api.request("POST", "/v1/providers/openai/connect", .object([:]))
            guard let attempt = response["attempt"]["id"].string ?? response["attempt"].string,
                  let address = response["authorizationUrl"].string, let url = URL(string: address), url.scheme == "https" else {
                throw ExecError("The backend returned an invalid sign-in challenge.")
            }
            attemptID = attempt
            defer { attemptID = nil }
            if cancellationRequested {
                await cancelConnection()
                throw ExecError("Sign-in was interrupted.")
            }
            guard NSWorkspace.shared.open(url) else {
                await cancelConnection()
                throw ExecError("Could not open the sign-in page in your browser.")
            }
            while true {
                try Task.checkCancellation()
                let state = try await api.get("/v1/connection-attempt")
                guard state["id"].string == attempt else { throw ExecError("The sign-in attempt changed. Connect the provider again.") }
                switch state["state"].string {
                case "completed": break
                case "failed", "interrupted": throw ExecError(state["error"].string ?? "Sign-in was interrupted.")
                default: try await Task.sleep(for: .milliseconds(200)); continue
                }
                break
            }
        } else { throw ExecError("Unknown provider.") }
        try await refreshConnections()
    }
    func disconnect(id: String) async throws {
        do { _ = try await api.request("DELETE", "/v1/providers/\(id)") }
        catch { try? await refreshConnections(); throw error }
        try await refreshConnections()
    }
    func cancelConnection() async {
        cancellationRequested = true
        guard let attemptID, !cancellationSent else { return }
        cancellationSent = true
        _ = try? await api.request("POST", "/v1/connection-attempt/cancel", .object(["operationID": .string(attemptID)]))
    }
}
