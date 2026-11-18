import Foundation

/// Revision hints only. Fetch canonical snapshots/deltas to obtain changed content.
public struct RemoteChangeNotification: Codable, Sendable, Equatable {
    public let epoch: String
    public let catalog: String
    public let conversations: [String: String]

    public init(epoch: String, catalog: String, conversations: [String: String]) {
        self.epoch = epoch
        self.catalog = catalog
        self.conversations = conversations
    }
}
