import AppKit
import UniformTypeIdentifiers

/// One atomic mixed drop: failures leave the draft unchanged.
enum AttachmentDrop {
    struct Batch: Sendable {
        var images: [ImageAttachment] = []
        var files: [FileAttachment] = []
    }
    @MainActor static func load(_ providers: [NSItemProvider]) async throws -> Batch {
        guard !providers.isEmpty, providers.count <= 4 else { throw ExecError("Drop up to four attachments at a time.") }
        var batch = Batch()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let bytes = try await ImageDrop.data(from: provider, type: UTType.fileURL.identifier)
                guard let url = URL(dataRepresentation: bytes, relativeTo: nil), url.isFileURL else {
                    throw ExecError("Drop a local file, not a web link.")
                }
                let item = try await Task.detached(priority: .userInitiated) { try loadFile(url) }.value
                batch.images += item.images
                batch.files += item.files
            } else {
                batch.images += try await ImageDrop.load([provider])
            }
        }
        return batch
    }
    static func loadFile(_ url: URL) throws -> Batch {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ExecError("Attach regular files, not folders, packages, or symbolic links.")
        }
        if values.contentType?.conforms(to: .image) == true {
            return Batch(images: [try ImageDrop.loadFile(url)])
        }
        guard (values.fileSize ?? Int.max) <= FileAttachment.maximumBytes else {
            throw ExecError("Attach files no larger than 8 MB.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: FileAttachment.maximumBytes + 1) ?? Data()
        let attachment = FileAttachment(name: url.lastPathComponent, data: data)
        try FileAttachment.validate([attachment])
        return Batch(files: [attachment])
    }
}
