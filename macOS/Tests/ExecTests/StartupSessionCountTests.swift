import Foundation

@MainActor struct StartupSessionCountTests {
    private func fixture(_ id: UUID, metadata: [String: Any]? = nil, version: Int = 1) throws -> Data {
        var record: [String: Any] = [
            "version": version, "id": id.uuidString.lowercased(),
            "model": "fixture-model", "workspace": "/fixture", "maxSteps": 10,
            "messages": [], "operation": NSNull(), "executingToolID": NSNull()
        ]
        if let metadata { record["metadata"] = metadata }
        return try JSONSerialization.data(withJSONObject: record)
    }

    func countsZeroOneAndMultipleSessions() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: profile) }
        try expect(AgentService.savedSessionCount(in: profile) == 0)
        let directory = profile.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try expect(AgentService.savedSessionCount(in: profile) == 0)
        for count in 1...3 {
            let id = UUID()
            // Older records omit metadata; newer root sessions may have a null parent.
            let data = try fixture(id, metadata: count == 1 ? nil : ["parent": NSNull()])
            try data.write(to: directory.appendingPathComponent("\(id.uuidString.lowercased()).json"))
            try expect(AgentService.savedSessionCount(in: profile) == count)
        }
    }

    func ignoresChildrenAndInvalidFiles() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: profile) }
        let directory = profile.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = UUID()
        let data = try fixture(root)
        let rootFile = directory.appendingPathComponent("\(root.uuidString.lowercased()).json")
        try data.write(to: rootFile)
        let child = UUID()
        try fixture(child, metadata: ["parent": ["sessionId": root.uuidString.lowercased()]], version: 9)
            .write(to: directory.appendingPathComponent("\(child.uuidString.lowercased()).json"))
        try data.write(to: directory.appendingPathComponent("library.json"))
        try data.write(to: directory.appendingPathComponent("\(UUID().uuidString).json")) // mismatched ID
        try Data("{broken".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("\(UUID().uuidString).json"))
        let unsupported = UUID()
        try fixture(unsupported, version: 999)
            .write(to: directory.appendingPathComponent("\(unsupported.uuidString).json"))
        let staged = UUID()
        try fixture(staged).write(to: directory.appendingPathComponent("\(staged.uuidString).tmp"))
        let nested = directory.appendingPathComponent("\(UUID().uuidString).json")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try data.write(to: nested.appendingPathComponent(rootFile.lastPathComponent))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("\(UUID().uuidString).json"), withDestinationURL: rootFile)
        try expect(AgentService.savedSessionCount(in: profile) == 1)
        try FileManager.default.removeItem(at: rootFile)
        try expect(AgentService.savedSessionCount(in: profile) == 0)
    }
}
