import Foundation

/// Supplies display identity while Keychain is still being restored. It has no
/// transport, credentials or executable conversation context. Even accidental
/// calls fail closed; the library replaces it before enabling any actions.
@MainActor final class PresentationProvider: ChatProvider {
    private let presentation: AccountPresentation
    init(_ presentation: AccountPresentation) { self.presentation = presentation }
    var displayName: String { presentation.providerName }
    var connectionTitle: String { presentation.connectionTitle }
    var account: String? { presentation.accountName }
    var conversationIdentity: String? { presentation.conversationIdentity }
    func makeConversationProvider() throws -> any ChatProvider { PresentationProvider(presentation) }
    private var unavailable: ExecError { ExecError("The account has not finished restoring.") }
    func connect() async throws { throw unavailable }
    func disconnect() async throws { throw unavailable }
    func models() async throws -> [ChatModel] { throw unavailable }
    func encodeConversationState() throws -> Data? { throw unavailable }
    func restoreConversationState(_ data: Data?, history: [Message]) throws { throw unavailable }
    func send(_ messages: [Message], model: String, effort: String?, instructions: String,
              tools: [ToolDefinition]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: unavailable) }
    }
}
