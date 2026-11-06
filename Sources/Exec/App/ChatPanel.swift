import Foundation
import Observation

/// Window-local controls targeting one existing conversation. The library still
/// owns all runners, account state, persistence, and application-wide shutdown.
@MainActor @Observable final class ChatPanel {
    let library: ChatLibrary
    let current: ChatStore

    init(library: ChatLibrary, conversation: ChatStore) {
        self.library = library
        current = conversation
    }

    var navigating: Bool { library.navigating }
    var canNavigate: Bool {
        !library.navigating && !library.authenticating && library.openConversations.contains { $0 === current }
    }
    var busy: Bool { !canNavigate || current.busy }
    var isWorking: Bool { library.authenticating || current.busy }
    var isSending: Bool { current.isSending }
    var canEditDraft: Bool { canNavigate && current.canEditDraft }
    var models: [ChatModel] { library.models }
    var account: String? { current.account }
    var accountUsage: AccountUsage? { library.accountUsage }
    var workspace: Workspace? { current.workspace }
    var autoApproveTools: Bool { current.autoApproveTools }
    var canCompact: Bool { canNavigate && current.canCompact }
    var canSelectWorkspace: Bool { canNavigate && !current.busy && current.messages.isEmpty }
    var draft: String {
        get { current.draft }
        set { if canNavigate { current.draft = newValue } }
    }
    var selectedModel: String {
        get { current.selectedModel }
        set {
            guard !busy, newValue != current.selectedModel else { return }
            current.selectedModel = newValue
            current.scheduleSave()
        }
    }
    var selectedEffort: String? {
        get { current.effectiveEffort }
        set {
            guard !busy, newValue == nil || current.model?.efforts.contains(where: { $0.id == newValue }) == true else { return }
            current.selectedEffort = newValue
            current.scheduleSave()
        }
    }

    func send() { if canNavigate { library.send(in: current) } }
    func resumeQueuedMessages() { if canNavigate { library.resumeQueuedMessages(in: current) } }
    func selectWorkspace(_ url: URL) { library.selectWorkspace(url, in: current) }
    func compact() { if canCompact { current.compact() } }
    func setAutoApproveTools(_ enabled: Bool) { if canNavigate { current.setAutoApproveTools(enabled) } }
    func stop() {
        guard !navigating else { return }
        if library.authenticating { library.stop() }
        else { current.stop() }
    }
}
