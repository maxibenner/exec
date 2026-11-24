import Foundation

@MainActor struct AgentBundleConfigurationTests {
    func defaultsAndOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try AgentBundleConfiguration(info: [:])
        try expect(defaults.profileName == "Exec" && defaults.port == 8765)
        try expect(defaults.profile(in: root).path == root.appendingPathComponent("Exec/Agent").path)
        let profileOnly = try AgentBundleConfiguration(info: ["ExecProfileName": "Exec-Test"])
        try expect(profileOnly.profileName == "Exec-Test" && profileOnly.port == 8765)
        let portOnly = try AgentBundleConfiguration(info: ["ExecAgentPort": 18765])
        try expect(portOnly.profileName == "Exec" && portOnly.port == 18765)

        for (name, port) in [("Exec Test", 1), ("Exec.Tests", 18765), ("Exec-图像", 65535)] {
            // Exercise the same Foundation value types supplied by Info.plist.
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["ExecProfileName": name, "ExecAgentPort": port], format: .xml, options: 0)
            let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
            let http = try AgentHTTPConfiguration(info: info)
            try expect(http.bundleConfiguration.profileName == name && http.port == UInt16(port))
            try expect(http.bundleConfiguration.profile(in: root).path == root.appendingPathComponent("\(name)/Agent").path)
            let transport = http.transport // Construct only; never issue a request.
            try expect(transport.host == "127.0.0.1" && transport.port == UInt16(port) && !transport.usesTLS)
        }
    }

    func rejectsInvalidProfiles() throws {
        let values: [Any] = ["", "   ", ".", "..", "/", "../Exec", "Exec/Test", "Exec\\Test",
                             "Exec\nTest", "Exec\tTest", "Exec\u{0}", "Exec\u{7F}", "Exec\u{85}",
                             123, true, ["Exec"], NSNull()]
        for value in values {
            try expectRejected(["ExecProfileName": value], key: "ExecProfileName")
        }
    }

    func rejectsInvalidPorts() throws {
        let values: [Any] = [0, -1, 65536, Int.max, "8765", "", true, false,
                             8765.0, 1.5, [8765], NSNull()]
        for value in values {
            try expectRejected(["ExecAgentPort": value], key: "ExecAgentPort")
        }
    }

    func savedChecksStayIsolatedAndFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let production = try AgentBundleConfiguration(info: [:]).profile(in: root)
        let isolated = try AgentBundleConfiguration(info: ["ExecProfileName": "Exec-Test"]).profile(in: root)
        try saveSession(in: production)
        try expect(AgentService.hasSavedSessions(in: production))
        try expect(AgentService.savedSessionCount(in: production) == 1)
        try expect(!AgentService.hasSavedSessions(in: isolated))
        try expect(AgentService.savedSessionCount(in: isolated) == 0)
        try saveSession(in: isolated)
        try saveSession(in: isolated)
        try expect(AgentService.hasSavedSessions(in: isolated))
        try expect(AgentService.savedSessionCount(in: isolated) == 2)
        try expect(AgentService.savedSessionCount(in: production) == 1)

        let invalidConfigurations: [[String: Any]] = [["ExecProfileName": "../Exec"], ["ExecAgentPort": 0]]
        for info in invalidConfigurations {
            let invalid = try? AgentBundleConfiguration(info: info).profile(in: root)
            try expect(invalid == nil)
            try expect(!AgentService.hasSavedSessions(in: invalid))
            try expect(AgentService.savedSessionCount(in: invalid) == 0)
        }
    }

    private func expectRejected(_ info: [String: Any], key: String) throws {
        try expect((try? AgentBundleConfiguration(info: info)) == nil)
        do {
            _ = try AgentHTTPConfiguration(info: info)
            throw CheckFailure(description: "Accepted invalid \(key)")
        } catch let error as ExecError {
            try expect(error.message.contains(key))
        }
    }

    private func saveSession(in profile: URL) throws {
        let directory = profile.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "id": id])
        try data.write(to: directory.appendingPathComponent("\(id).json"))
    }
}
