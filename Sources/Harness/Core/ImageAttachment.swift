import Foundation

struct ImageAttachment: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let mediaType: String
    let data: Data

    init(id: UUID = UUID(), name: String, mediaType: String, data: Data) {
        self.id = id; self.name = name; self.mediaType = mediaType; self.data = data
    }

    static let maximumCount = 4
    static let maximumTotalBytes = 8 * 1024 * 1024

    static func validate(_ images: [Self]) throws {
        guard images.count <= maximumCount,
              images.allSatisfy({ !$0.data.isEmpty && ["image/jpeg", "image/png"].contains($0.mediaType) }),
              images.reduce(0, { $0 + $1.data.count }) <= maximumTotalBytes else {
            throw HarnessError("Attach up to four images, totaling no more than 8 MB after resizing.")
        }
    }
}
