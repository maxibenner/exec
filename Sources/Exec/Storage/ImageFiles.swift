import Foundation
import Darwin
import CryptoKit

/// Image files are immutable and addressed by content, so repeated checkpoints
/// and duplicate transcript/history references share the same bytes.
struct ImageFiles: Sendable {
    static let codingKey = CodingUserInfoKey(rawValue: "imageDirectory")!
    let directory: URL
    static let limit = 32 * 1024 * 1024

    func save(_ data: Data, mediaType: String) throws -> String {
        guard ["image/png", "image/jpeg"].contains(mediaType) else { throw ExecError("Unsupported image type.") }
        let suffix = mediaType == "image/png" ? ".png" : ".jpg"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let name = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + suffix
        if let existing = try? load(name) {
            guard existing == data else { throw ExecError("Image artifact collision.") }
            return name
        }
        try Self.create(data, path: name, root: directory)
        return name
    }

    func load(_ path: String) throws -> Data {
        guard path.count == 68, path.hasSuffix(".png") || path.hasSuffix(".jpg"),
              path.dropLast(4).allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw ExecError("Invalid saved image path.")
        }
        let fd = try WorkspaceFiles(root: directory).openPath(path, directory: false)
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= Self.limit else { throw ExecError("Invalid saved image file.") }
        let data = try file.read(upToCount: Self.limit + 1) ?? Data()
        guard data.count <= Self.limit,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == String(path.dropLast(4)) else {
            throw ExecError("Saved image is damaged.")
        }
        return data
    }

    /// Publish only complete files, without replacing an existing destination.
    static func create(_ data: Data, path: String, root: URL) throws {
        guard !data.isEmpty, data.count <= limit else { throw ExecError("Invalid image size.") }
        let parent = try WorkspaceFiles(root: root).parent(of: path)
        defer { close(parent.descriptor) }
        let temporary = ".image-\(UUID().uuidString)"
        let fd = openat(parent.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ExecError("Cannot create image file.") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); unlinkat(parent.descriptor, temporary, 0) }
        try file.write(contentsOf: data)
        try file.synchronize()
        guard linkat(parent.descriptor, temporary, parent.descriptor, parent.name, 0) == 0 else {
            throw ExecError("Cannot save image: destination exists or is not writable.")
        }
    }
}
