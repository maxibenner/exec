import Foundation
import Observation

@MainActor @Observable final class ChatStore {
    var messages: [Message] = []
    var draft = ""
    var models: [ChatModel] = []
    var selectedModel = ""
    var account: String?
    var connectionTitle: String { provider.connectionTitle }
    var error: String?
    private(set) var busy = false
    private var history: [Message] = []
    private let provider: any ChatProvider
    private var task: Task<Void, Never>?

    init(provider: any ChatProvider) {
        self.provider = provider
        account = provider.account
    }

    func restore() {
        guard account != nil else { return }
        run { try await self.loadModels() }
    }

    func connect() {
        run {
            try await self.provider.connect()
            self.account = self.provider.account
            try await self.loadModels()
        }
    }

    func disconnect() {
        run {
            defer {
                self.account = self.provider.account
                self.models = []; self.selectedModel = ""
                self.history = []; self.messages = []
            }
            try await self.provider.disconnect()
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, account != nil, !selectedModel.isEmpty else { return }
        let user = Message(role: .user, text: text)
        let input = history + [user]
        messages.append(user)
        messages.append(Message(role: .assistant, text: ""))
        let index = messages.count - 1
        draft = ""
        run {
            var fullText = ""
            var lastUpdate = ContinuousClock.now
            var completed = false
            defer { self.messages[index].text = fullText }
            for try await event in self.provider.send(input, model: self.selectedModel) {
                try Task.checkCancellation()
                switch event {
                case .text(let delta):
                    fullText += delta
                    if lastUpdate.duration(to: .now) >= .milliseconds(40) {
                        self.messages[index].text = fullText
                        lastUpdate = .now
                    }
                case .completed: completed = true
                }
            }
            guard completed else { throw HarnessError("Response did not complete.") }
            self.history = input + [Message(role: .assistant, text: fullText)]
        }
    }

    func stop() { task?.cancel() }

    func newConversation() {
        guard !busy else { return }
        messages = []; history = []; error = nil
    }

    private func loadModels() async throws {
        models = try await provider.models()
        selectedModel = models.first?.id ?? ""
        if models.isEmpty { throw HarnessError("The provider returned no selectable models. Try reconnecting or updating Harness.") }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        task = Task {
            defer { self.busy = false; self.task = nil }
            do { try await operation() }
            catch {
                self.error = Task.isCancelled ? "Stopped. The unfinished turn won't be included in the next message." : error.localizedDescription
            }
        }
    }
}
