import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Copies drop data immediately; saved messages never depend on the original file or a remote URL.
enum ImageDrop {
    static let maximumSourceBytes = 20 * 1024 * 1024

    @MainActor static func load(_ providers: [NSItemProvider]) async throws -> [ImageAttachment] {
        guard !providers.isEmpty, providers.count <= ImageAttachment.maximumCount else {
            throw ExecError("Drop up to four images at a time.")
        }
        var images: [ImageAttachment] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                let data = try await data(from: provider, type: UTType.fileURL.identifier)
                guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                    throw ExecError("Drop an image file, not a web link.")
                }
                images.append(try await Task.detached(priority: .userInitiated) {
                    try loadFile(url)
                }.value)
            } else {
                guard let type = provider.registeredTypeIdentifiers.first(where: {
                    UTType($0)?.conforms(to: .image) == true
                }) else { throw ExecError("This drop does not contain an image.") }
                let data = try await data(from: provider, type: type)
                let name = provider.suggestedName ?? "Image"
                images.append(try await Task.detached(priority: .userInitiated) {
                    try normalize(data, name: name)
                }.value)
            }
        }
        try ImageAttachment.validate(images)
        return images
    }

    @MainActor private static func data(from provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? ExecError("Could not read the dropped image.")) }
            }
        }
    }

    static func loadFile(_ url: URL) throws -> ImageAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= maximumSourceBytes else {
            throw ExecError("Drop an image file smaller than 20 MB.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumSourceBytes + 1) ?? Data()
        return try normalize(data, name: url.lastPathComponent)
    }

    static func normalize(_ data: Data, name: String) throws -> ImageAttachment {
        guard !data.isEmpty, data.count <= maximumSourceBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32_768, height <= 32_768,
              Double(width) * Double(height) <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048
              ] as CFDictionary) else {
            throw ExecError("Use a valid, non-animated image under 20 MB and 100 megapixels.")
        }
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let type: UTType = hasAlpha ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw ExecError("Could not prepare the dropped image.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 4 * 1024 * 1024 else {
            throw ExecError("The image is too large after resizing. Try a smaller image.")
        }
        return ImageAttachment(name: name, mediaType: hasAlpha ? "image/png" : "image/jpeg", data: output as Data)
    }
}
