import Foundation

// Intercepts only the URLSession created by makeSession. No test reads real
// credentials or sends traffic to OpenAI. A queue keeps scenarios explicit.
final class HTTPStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var error: URLError?
        var holdOpen = false
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Reply] = []
        private var received: [URLRequest] = []
        private var stopped: [URL] = []
        private var held: [HTTPStub] = []

        func reset(_ replies: [Reply]) {
            lock.withLock { self.replies = replies; received = []; stopped = []; held = [] }
        }
        func receive(_ request: URLRequest) -> Reply {
            lock.withLock {
                received.append(request)
                return replies.isEmpty ? Reply(error: URLError(.badServerResponse)) : replies.removeFirst()
            }
        }
        func hold(_ response: HTTPStub) { lock.withLock { held.append(response) } }
        func finishHeld() {
            let responses = lock.withLock { let result = held; held = []; return result }
            for response in responses { response.client?.urlProtocolDidFinishLoading(response) }
        }
        func stop(_ url: URL?) {
            lock.withLock {
                if let url { stopped.append(url) }
                held.removeAll { $0.request.url == url }
            }
        }
        var heldCount: Int { lock.withLock { held.count } }
        var requests: [URLRequest] { lock.withLock { received } }
        var stoppedURLs: [URL] { lock.withLock { stopped } }
    }
    static let state = State()

    static func makeSession(_ replies: [Reply]) -> URLSession {
        state.reset(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStub.self]
        configuration.timeoutIntervalForRequest = 2
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.receive(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error) }
        else if reply.holdOpen { Self.state.hold(self) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.state.stop(request.url) }

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { return body }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
}

final class MemoryCredentials: CredentialStore {
    var data: Data?
    var writes = 0
    var failWrite = 0
    func read(_ account: String) throws -> Data? { data }
    func write(_ data: Data, account: String) throws {
        writes += 1
        if writes == failWrite { throw ExecError("Keychain unavailable") }
        self.data = data
    }
    func delete(_ account: String) throws { data = nil }
}
