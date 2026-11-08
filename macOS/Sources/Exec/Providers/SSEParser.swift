import Foundation

// Incremental SSE framing, independent of TCP chunk boundaries. Supports CRLF,
// multiline data, comments, and bounded event sizes.
struct SSEParser {
    private var line = Data()
    private var payload = Data()
    private var size = 0

    mutating func push(_ byte: UInt8) throws -> Data? {
        size += 1
        guard size <= 4 * 1024 * 1024 else { throw ExecError("Stream event exceeded the size limit.") }
        guard byte == 10 else { line.append(byte); return nil }
        if line.last == 13 { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            size = 0
            guard !payload.isEmpty else { return nil }
            payload.removeLast()
            let event = payload
            payload = Data()
            return event
        }
        if line.starts(with: Data("data:".utf8)) {
            var value = line.dropFirst(5)
            if value.first == 32 { value = value.dropFirst() }
            payload.append(contentsOf: value)
            payload.append(10)
        }
        return nil
    }
}
