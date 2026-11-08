import Foundation

struct ShellOutputTests {
    static func logURL(in result: String) throws -> URL {
        guard let marker = result.range(of: "saved to temporary log: "),
              let end = result[marker.upperBound...].firstIndex(of: "\n") else {
            throw CheckFailure(description: "Missing shell output log path")
        }
        return URL(fileURLWithPath: String(result[marker.upperBound..<end]))
    }

    func boundariesAndFullLog() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for count in [0, 16_384, 32_768] {
            let capture = ShellOutputCapture(temporaryDirectory: root)
            let text = String(repeating: "x", count: count)
            capture.append(Data(text.utf8))
            try expect(capture.finish() == text)
        }
        let unicode = ShellOutputCapture(temporaryDirectory: root)
        let bytes = Data("café 🛠\n".utf8)
        for byte in bytes { unicode.append(Data([byte])) }
        try expect(unicode.finish() == String(decoding: bytes, as: UTF8.self))
        try expect(FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        // Exercise both the one-byte overflow boundary and multiple pipe-sized chunks.
        for count in [32_769, 200_000] {
            let capture = ShellOutputCapture(temporaryDirectory: root)
            let bytes = Data((0..<count).map { UInt8(65 + $0 % 26) })
            for start in stride(from: 0, to: count, by: 8192) {
                capture.append(bytes.subdata(in: start..<min(start + 8192, count)))
            }
            let result = capture.finish()
            try expect(result.hasPrefix(String(decoding: bytes.prefix(16_384), as: UTF8.self)))
            try expect(result.contains(String(decoding: bytes.suffix(16_384), as: UTF8.self)))
            try expect(result.contains("\(count - 32_768) bytes omitted"))
            try expect(result.utf8.count < 34_000)
            let url = try Self.logURL(in: result)
            try expect(Data(contentsOf: url) == bytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            try expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
    }

    func logFailureAndUnpublishedCleanup() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unavailable = root.appendingPathComponent("missing")
        let capture = ShellOutputCapture(temporaryDirectory: unavailable)
        capture.append(Data(repeating: 65, count: 40_000))
        // Making storage available later must not trigger another attempt or a partial log.
        try FileManager.default.createDirectory(at: unavailable, withIntermediateDirectories: false)
        capture.append(Data("FINAL ERROR".utf8))
        let result = capture.finish()
        try expect(result.contains("FINAL ERROR") && result.contains("Full output log unavailable"))
        try expect(!result.contains("saved to temporary log:"))
        try expect(FileManager.default.contentsOfDirectory(atPath: unavailable.path).isEmpty)
        try FileManager.default.removeItem(at: unavailable)

        func discardCapture() throws {
            let unpublished = ShellOutputCapture(temporaryDirectory: root)
            unpublished.append(Data(repeating: 66, count: 40_000))
            try expect(FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
            // No finish: cancellation/error does not publish or retain this log.
        }
        try discardCapture()
        try expect(FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func timeoutPreservesDiagnostics() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await ShellRunner.run(
            "printf 'START\\n'; /usr/bin/yes x | /usr/bin/head -c 100000; printf 'BEFORE TIMEOUT\\n' >&2; sleep 10",
            in: root, timeout: .seconds(1))
        let url = try Self.logURL(in: result)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try expect(result.contains("timed out") && !result.contains("Exit code: 0"))
        try expect(result.contains("START\n") && result.contains("BEFORE TIMEOUT\n"))
        let expected = Data(("START\n" + String(repeating: "x\n", count: 50_000) + "BEFORE TIMEOUT\n").utf8)
        try expect(Data(contentsOf: url) == expected)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
