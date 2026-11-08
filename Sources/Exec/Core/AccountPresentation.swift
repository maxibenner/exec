import Foundation

/// Last-known presentation only. This is not a credential or authorization proof.
struct AccountPresentation: Codable, Equatable, Sendable {
    let providerName: String
    let connectionTitle: String
    let accountName: String
    let conversationIdentity: String

    var metadataKey: String { providerName + ":" + conversationIdentity }
}
