import Foundation

enum ImageGenerationTool {
    static let definition = ToolDefinition(name: "generate_image", description: "Generate one image using the connected subscription. The prompt is sent to the provider and the image is saved in this conversation, not the workspace. Uses image-generation quota. Only call when the user requests an image. Failures stop the turn; never retry failed or interrupted generation without a new user request.", parameters: [
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

    static let interrupted = "Image generation did not complete locally. The provider may have generated an image and charged subscription quota. No image was saved and no automatic retry was made. Do not retry without a new user request."
}
