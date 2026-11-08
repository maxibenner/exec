import Foundation
import ImageIO

// Mirrors Codex's standalone ImagesClient, not the public API-key Responses tool.
// https://github.com/openai/codex/tree/main/codex-rs/ext/image-generation
// https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/endpoint/images.rs
enum CodexImages {
    static let maximumResponseBytes = 12 * 1024 * 1024

    static func request(_ input: ImageGenerationTool.Request, accessToken: String, accountID: String) throws -> URLRequest {
        let input = try input.validated()
        var request = CodexConnection.request(path: "/images/generations", accessToken: accessToken, accountID: accountID)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-codex-image-turn-id")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-image-2", "prompt": input.prompt,
            "background": input.transparent_background ? "transparent" : "opaque",
            "quality": "auto", "size": "auto"
        ])
        return request
    }

    static func image(_ data: Data) throws -> ImageAttachment {
        struct Response: Decodable {
            struct Image: Decodable { let b64_json: String }
            let data: [Image]
        }
        guard data.count <= maximumResponseBytes,
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.data.count == 1,
              let bytes = Data(base64Encoded: response.data[0].b64_json),
              !bytes.isEmpty, bytes.count <= ImageAttachment.maximumTotalBytes,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height),
              width * height <= 32_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw ExecError("Image generation returned missing, invalid, or oversized image data. No retry was made.")
        }
        let png = type == "public.png"
        return ImageAttachment(name: "Generated image.\(png ? "png" : "jpg")",
                               mediaType: png ? "image/png" : "image/jpeg", data: bytes)
    }
}
