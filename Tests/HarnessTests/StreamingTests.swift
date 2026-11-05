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
        guard case .completed(let output, _) = completed else { throw HarnessError("Missing completion") }
        let items = try JSONSerialization.jsonObject(with: output) as? [[String: String]]
        try expect(items?.first?["encrypted_content"] == "opaque")
    }

    func completedItemsMergeWithoutDuplicatingOrLosingContext() throws {
        var decoder = OpenAITransport.ResponseDecoder()
        let message = Data(#"{"type":"response.output_item.done","output_index":1,"item":{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}}"#.utf8)
        let reasoning = Data(#"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs_1","type":"reasoning","summary":[]}}"#.utf8)
        try expect(decoder.decode(message) == nil)
        try expect(decoder.decode(reasoning) == nil)
        let terminal = Data(#"{"type":"response.completed","response":{"status":"completed","output":[{"id":"rs_1","type":"reasoning","encrypted_content":"opaque"},{"id":"msg_1","type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}]}}"#.utf8)
        guard case .completed(let data, _) = try decoder.decode(terminal) else { throw HarnessError("Missing completion") }
        let output = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        try expect(output.count == 2)
        try expect(output[0]["encrypted_content"] as? String == "opaque" && output[0]["summary"] != nil)
        try expect(output[1]["id"] as? String == "msg_1")

        var failed = OpenAITransport.ResponseDecoder()
        try expect(failed.decode(Data(#"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"shell","arguments":"{}"}}"#.utf8)) == nil)
        try expectFailure {
            _ = try failed.decode(Data(#"{"type":"response.failed","response":{"status":"failed"}}"#.utf8))
        }
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
