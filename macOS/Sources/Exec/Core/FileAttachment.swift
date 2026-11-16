import Foundation

/// Draft bytes are copied at drop time. Transcript attachments keep only the managed reference.
struct FileAttachment: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    var data: Data = Data()
    var path: String?

    init(id: UUID = UUID(), name: String, data: Data = Data(), path: String? = nil) {
        self.id = id; self.name = name; self.data = data; self.path = path
    }
    static let maximumBytes = 8 * 1024 * 1024
    static func validate(_ files: [Self]) throws {
        guard files.count <= 4, files.allSatisfy({
            $0.data.count <= maximumBytes && !$0.name.isEmpty && $0.name.utf8.count <= 255 &&
            ![".", ".."].contains($0.name) && !$0.name.contains("/") && !$0.name.contains("\\") &&
            $0.name.rangeOfCharacter(from: .controlCharacters) == nil
        }) else { throw ExecError("Attach up to four files, each no larger than 8 MB, with valid filenames.") }
    }
}
