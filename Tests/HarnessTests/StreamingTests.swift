import Foundation

struct StreamingTests {
    func framesCommentsMultilineAndUnicode() throws {
        let source = ": heartbeat\r\n\r\nevent: message\r\ndata: {\"delta\":\r\ndata: \"Hello 🌍\"}\r\n\r\ndata: second\n\n"
        var parser = SSEParser()
        var events: [Data] = []
        for byte in source.utf8 {
            if let event = try parser.push(byte) { events.append(event) }
        }
        try expect(events.map { String(decoding: $0, as: UTF8.self) } == ["{\"delta\":\n\"Hello 🌍\"}", "second"])
    }

    func partialFrameDoesNotEmit() throws {
        var parser = SSEParser()
        for byte in "data: unfinished\n".utf8 { try expect(try parser.push(byte) == nil) }
    }

    func oversizedEventIsRejected() throws {
        try expectFailure {
            var parser = SSEParser()
            for _ in 0...(4 * 1024 * 1024) { _ = try parser.push(65) }
        }
    }

    func semanticEvents() throws {
        let text = try OpenAITransport.decode(Data(#"{"type":"response.output_text.delta","delta":"hello"}"#.utf8))
        guard case .text(let delta) = text else { throw HarnessError("Missing text event") }
        try expect(delta == "hello")
        let completed = try OpenAITransport.decode(Data(#"{"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","encrypted_content":"opaque"}]}}"#.utf8))
        guard case .completed(let output) = completed else { throw HarnessError("Missing completion") }
        let items = try JSONSerialization.jsonObject(with: output) as? [[String: String]]
        try expect(items?.first?["encrypted_content"] == "opaque")
    }

    func errorsAndIncompleteAreNotSuccess() throws {
        for type in ["response.failed", "response.incomplete", "error", "response.completed"] {
            try expectFailure {
                _ = try OpenAITransport.decode(Data("{\"type\":\"\(type)\"}".utf8))
            }
        }
    }

    func formEncodingEscapesReservedCharacters() throws {
        let encoded = String(decoding: OpenAIHTTP.form(["code": "a+b &/?=é"]), as: UTF8.self)
        try expect(encoded == "code=a%2Bb%20%26%2F%3F%3D%C3%A9")
    }
}
