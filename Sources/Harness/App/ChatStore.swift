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
    private(set) var workspace: Workspace?
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
                if self.account == nil {
                    self.models = []; self.selectedModel = ""
                    self.history = []; self.messages = []
                }
            }
            try await self.provider.disconnect()
        }
    }

    /// Selection is transactional: a failed load leaves the old chat and workspace intact.
    func selectWorkspace(_ url: URL) {
        run {
            let loading = Task.detached(priority: .userInitiated) { try Workspace.load(url) }
            let workspace = try await withTaskCancellationHandler {
                try await loading.value
            } onCancel: { loading.cancel() }
            try Task.checkCancellation()
            self.newConversationForWorkspace(workspace)
        }
    }

    func closeWorkspace() {
        guard !busy else { return }
        newConversationForWorkspace(nil)
    }

    private func newConversationForWorkspace(_ workspace: Workspace?) {
        self.workspace = workspace
        messages = []; history = []; draft = ""; error = nil
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy, account != nil, !selectedModel.isEmpty else { return }
        let user = Message(role: .user, text: text)
        let input = history + [user]
        messages.append(user)
        messages.append(Message(role: .assistant, text: "", status: .streaming))
        let index = messages.count - 1
        draft = ""
        run {
            var fullText = ""
            var lastUpdate = ContinuousClock.now
            var completed = false
            defer {
                self.messages[index].text = fullText
                if self.messages[index].status == .streaming {
                    self.messages[index].status = Task.isCancelled ? .interrupted : .failed
                }
            }
            for try await event in self.provider.send(input, model: self.selectedModel, instructions: self.workspace?.modelInstructions ?? "") {
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
            try Task.checkCancellation()
            guard completed else { throw HarnessError("Response did not complete.") }
            self.messages[index].status = .complete
            self.history = input + [Message(role: .assistant, text: fullText)]
        }
    }

    func stop() { task?.cancel() }

    func newConversation() {
        guard !busy else { return }
        messages = []; history = []; error = nil
    }

    private func loadModels() async throws {
        let available = try await provider.models()
        try Task.checkCancellation()
        models = available
        if !models.contains(where: { $0.id == selectedModel }) { selectedModel = models.first?.id ?? "" }
        if models.isEmpty { throw HarnessError("The provider returned no selectable models. Try reconnecting or updating Harness.") }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        task = Task {
            defer {
                self.account = self.provider.account
                self.busy = false
                self.task = nil
            }
            do { try await operation() }
            catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.error = "Stopped. Any unfinished turn is excluded from follow-up context."
                } else if let network = error as? URLError {
                    self.error = network.code == .timedOut
                        ? "The connection timed out. Your completed conversation is intact; try again when ready."
                        : "Could not reach the provider. Check your connection and try again."
                } else {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}
