import Foundation

struct DeepSeekConversationState: Codable {
    struct Measurement: Codable {
        let inputID: UUID
        let model: String
        let tokens: Int
    }
    var version = 1
    // Like Codex, key completed output by the last input, before ChatStore assigns
    // its assistant message ID. Never cache reasoning from an interrupted stream.
    var reasoning: [UUID: String] = [:]
    var measurement: Measurement?

    func input(_ messages: [Message], instructions: String, acceptsImages: Bool) throws -> [[String: Any]] {
        var result: [[String: Any]] = instructions.isEmpty ? [] : [["role": "system", "content": instructions]]
        var previousID: UUID?
        for message in messages {
            defer { previousID = message.id }
            if let tool = message.toolResult {
                let images = [tool.screenshot ?? tool.generatedImage].compactMap { $0 }
                result.append(["role": "tool", "tool_call_id": tool.call.id,
                               "content": try content(tool.text, images: images, acceptsImages: acceptsImages)])
            } else if message.role == .assistant {
                var item: [String: Any] = ["role": "assistant", "content": message.text]
                if message.status == .complete {
                    // Imported turns from another provider have no DeepSeek reasoning.
                    // An explicit empty value keeps the tool-enabled wire format valid.
                    item["reasoning_content"] = previousID.flatMap { reasoning[$0] } ?? ""
                    if !message.toolCalls.isEmpty {
                        item["tool_calls"] = message.toolCalls.map {
                            ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] as [String: Any]
                        }
                    }
                } else {
                    guard !message.text.isEmpty else { continue }
                    item["content"] = "[Incomplete assistant response.]\n\n" + message.text
                    item["reasoning_content"] = ""
                }
                result.append(item)
            } else if message.role == .user {
                result.append(["role": "user", "content": try content(message.text, images: message.images, acceptsImages: acceptsImages)])
            }
        }
        return result
    }

    private func content(_ text: String, images: [ImageAttachment], acceptsImages: Bool) throws -> Any {
        guard !images.isEmpty else { return text }
        guard acceptsImages else {
            throw ExecError("This DeepSeek model does not accept images. Select an image-capable model to continue this conversation.")
        }
        try ImageAttachment.validate(images)
        var parts: [[String: Any]] = []
        if !text.isEmpty { parts.append(["type": "text", "text": text]) }
        parts += images.map { ["type": "image_url", "image_url": ["url": "data:\($0.mediaType);base64,\($0.data.base64EncodedString())"]] }
        return parts
    }
}
