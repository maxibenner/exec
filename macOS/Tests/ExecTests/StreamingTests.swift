import Foundation

struct StreamingTests {
    func httpErrorDiagnostics() async throws {
        let body = Data(#"{"error":{"code":"missing_resource","message":"No resource for test-token or test-account","type":"invalid_request_error"},"access_token":"never-display"}"#.utf8)
        let request = CodexConnection.request(path: "/responses/compact", accessToken: "test-token", accountID: "test-account")
        for streaming in [true, false] {
            let session = HTTPStub.makeSession([.init(status: 404, chunks: [body])])
            defer { session.invalidateAndCancel() }
            do {
                if streaming {
                    for try await _ in OpenAITransport.stream(request, session: session) {}
                } else {
                    _ = try await OpenAITransport.boundedResponse(request, session: session)
                }
                throw CheckFailure(description: "Expected HTTP failure")
            } catch let error as OpenAIHTTPError {
                let text = error.localizedDescription
                try expect(error.status == 404 && text.contains("missing_resource"))
                try expect(text.contains("/responses/compact") && text.contains("No resource"))
                try expect(!text.contains("test-token") && !text.contains("test-account") && !text.contains("never-display"))
                try expect(HTTPStub.state.requests.count == 1)
            }
        }
        let auth = HTTPURLResponse(url: URL(string: OpenAIHTTP.auth + "/oauth/token")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        do {
            try OpenAIHTTP.check(auth, body: body)
            throw CheckFailure(description: "Expected auth failure")
        } catch let error as OpenAIHTTPError {
            try expect(error.details == nil)
        }
        for body in [Data("<html>private</html>".utf8), Data(repeating: 65, count: 17000), Data()] {
            let session = HTTPStub.makeSession([.init(status: 502, chunks: [body])])
            defer { session.invalidateAndCancel() }
            do {
                _ = try await OpenAITransport.boundedResponse(request, session: session)
                throw CheckFailure(description: "Expected bounded failure")
            } catch let error as OpenAIHTTPError {
                try expect(error.status == 502 && error.localizedDescription.count < 3000)
                try expect(!error.localizedDescription.contains("<html>"))
            }
        }
    }

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
        guard case .text(let delta) = text else { throw ExecError("Missing text event") }
        try expect(delta == "hello")
        let completed = try OpenAITransport.decode(Data(#"{"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","encrypted_content":"opaque"}]}}"#.utf8))
        guard case .completed(let output, _) = completed else { throw ExecError("Missing completion") }
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
        guard case .completed(let data, _) = try decoder.decode(terminal) else { throw ExecError("Missing completion") }
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
