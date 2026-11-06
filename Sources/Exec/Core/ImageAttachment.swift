import Foundation

struct ImageAttachment: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let mediaType: String
    let data: Data

    init(id: UUID = UUID(), name: String, mediaType: String, data: Data) {
        self.id = id; self.name = name; self.mediaType = mediaType; self.data = data
    }

    private enum CodingKeys: String, CodingKey { case id, name, mediaType, data, path }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        mediaType = try values.decode(String.self, forKey: .mediaType)
        if let path = try values.decodeIfPresent(String.self, forKey: .path) {
            guard let directory = decoder.userInfo[ImageFiles.codingKey] as? URL else {
                throw ExecError("Image storage is unavailable.")
            }
            data = try ImageFiles(directory: directory).load(path)
        } else {
            data = try values.decode(Data.self, forKey: .data)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(mediaType, forKey: .mediaType)
        if let directory = encoder.userInfo[ImageFiles.codingKey] as? URL {
            try values.encode(ImageFiles(directory: directory).save(data, mediaType: mediaType), forKey: .path)
        } else {
            try values.encode(data, forKey: .data)
        }
    }

    static let maximumCount = 4
    static let maximumTotalBytes = 8 * 1024 * 1024

    static func validate(_ images: [Self]) throws {
        guard images.count <= maximumCount,
              images.allSatisfy({ !$0.data.isEmpty && ["image/jpeg", "image/png"].contains($0.mediaType) }),
              images.reduce(0, { $0 + $1.data.count }) <= maximumTotalBytes else {
            throw ExecError("Attach up to four images, totaling no more than 8 MB after resizing.")
        }
    }
}
