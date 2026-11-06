import Foundation

enum ImageGenerationTool {
    static let definition = ToolDefinition(name: "generate_image", description: "Generate one image using the connected subscription. The prompt is sent to the provider. The image is stored in an app-managed file referenced by this conversation, not the workspace; the result includes its absolute path when persistent storage is available. Use shell to copy it when needed; do not modify the managed source. Uses image-generation quota. Only call when the user requests an image. Failures stop the turn; never retry failed or interrupted generation without a new user request.", parameters: [
        .init(name: "prompt", type: "string", description: "Describe the image to generate; at most 16 KiB. Do not include credentials or secrets."),
        .init(name: "transparent_background", type: "boolean", description: "Whether to request a transparent background; otherwise false")
    ])

    struct Request: Decodable, Sendable {
        let prompt: String
        let transparent_background: Bool

        func validated() throws -> Self {
            let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty, prompt.utf8.count <= 16_384, !prompt.contains("\0") else {
                throw ExecError("Use a nonempty image prompt of at most 16 KiB, without NUL bytes.")
            }
            return Self(prompt: prompt, transparent_background: transparent_background)
        }
    }

    static func request(_ call: ToolCall) throws -> Request {
        try CodingTools.decode(Request.self, call).validated()
    }

    static let interrupted = "Image generation did not complete locally. The provider may have generated an image and charged subscription quota. No completed image result was durably recorded; a managed image file may remain if local saving was interrupted. No automatic retry was made. Do not retry without a new user request."
}
