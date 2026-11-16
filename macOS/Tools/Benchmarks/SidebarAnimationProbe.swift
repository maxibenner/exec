import AppKit
import SwiftUI

/// Only synthetic snapshots are served. No sockets, accounts, Keychain or inference.
private actor SidebarProbeTransport: AgentTransport {
    var snapshots: [UUID: AgentJSON] = [:]
    var order: [UUID] = []
    var failNextOrder = false

    func install(_ values: [AgentJSON]) {
        snapshots = Dictionary(uniqueKeysWithValues: values.map { (UUID(uuidString: $0["id"].string!)!, $0) })
        order = values.map { UUID(uuidString: $0["id"].string!)! }
    }
    func reorder(_ ids: [UUID]) { order = ids }
    func failOrder() { failNextOrder = true }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        let route = String(path.split(separator: "?", maxSplits: 1)[0])
        let result: AgentJSON
        if route == "/v1/library" {
            if method == "PATCH", let body {
                // Make the persistence echo arrive while the native animation is running.
                try await Task.sleep(for: .milliseconds(80))
                if failNextOrder { failNextOrder = false; throw ExecError("Synthetic reorder failure") }
                let patch = try JSONDecoder().decode(AgentJSON.self, from: body)
                if case .array(let ids) = patch["order"] { order = ids.compactMap { $0.string.flatMap(UUID.init(uuidString:)) } }
            }
            var configuration = AgentLibraryConfiguration()
            configuration.order = order
            return try JSONEncoder().encode(configuration)
        } else if route == "/v1/conversations", method == "GET" {
            result = .array(order.compactMap { snapshots[$0] })
        } else if route == "/v1/conversations", method == "POST" {
            result = Self.snapshot(UUID(), title: "New conversation")
            let id = UUID(uuidString: result["id"].string!)!
            snapshots[id] = result
            order.insert(id, at: 0)
        } else {
            let pieces = route.split(separator: "/")
            guard pieces.count >= 3, let id = UUID(uuidString: String(pieces[2])),
                  let snapshot = snapshots[id] else { throw ExecError("Unexpected probe request: \(method) \(route)") }
            if method == "DELETE" {
                snapshots[id] = nil
                order.removeAll { $0 == id }
                result = .object([:])
            } else if route.hasSuffix("/sync") {
                result = .object(["snapshot": snapshot, "offset": .number(0), "total": .number(0),
                                  "reset": .bool(true), "prefix": .null])
            } else {
                result = snapshot
            }
        }
        return try JSONEncoder().encode(result)
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { _ in }
    }
    nonisolated static func snapshot(_ id: UUID, title: String, parent: UUID? = nil, activity: Double = 1000) -> AgentJSON {
        var metadata: [String: AgentJSON] = ["title": .string(title), "manuallyNamed": .bool(true), "activityAt": .number(activity)]
        if let parent {
            metadata["parent"] = .object(["sessionId": .string(parent.uuidString),
                "operationId": .string("aaaaaaaa-1111-4111-8111-111111111111"), "toolCallId": .string("probe")])
        }
        return .object(["id": .string(id.uuidString), "model": .string("deepseek/probe"), "workspace": .string("/tmp"),
            "configuration": .object(["settings": .object(["systemPrompt": .string(""), "autoApprove": .bool(true)]),
                "instructionsFrozen": .bool(true), "workspaceInstructions": .null]),
            "metadata": .object(metadata), "messages": .array([]), "pendingInput": .array([]),
            "operation": .null, "approval": .null, "activeToolCallID": .null, "storageError": .null])
    }
}

/// Added to a generated copy of SessionSidebar, never to the production view.
/// Transparent, noninteractive markers let us sample the actual presentation layers.
struct SidebarProbeMarker: NSViewRepresentable {
    let id: UUID
    let role: String
    func makeNSView(context: Context) -> Marker {
        let view = Marker()
        view.wantsLayer = true
        view.key = "\(role):\(id)"
        return view
    }
    func updateNSView(_ view: Marker, context: Context) { view.key = "\(role):\(id)" }
    final class Marker: NSView {
        var key = ""
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct ProbeWindow: View {
    let library: ChatLibrary
    let windows: SessionWindows
    let simpleDetail: Bool
    var body: some View {
        ChatWindowLayout(initiallyShowsSidebar: true) {
            SessionSidebar(store: library, open: windows.openSession, delete: { library.deleteSession($0.id) })
        } detail: {
            if simpleDetail { Text("Isolated detail") }
            else { ChatView(store: library, windows: windows) }
        }
    }
}

@main struct SidebarAnimationProbe {
    // The SDK's Reduce Motion environment value is read-only. The build script
    // injects this policy into its diagnostic copy, never changing OS preferences.
    static let reduceMotion = CommandLine.arguments.contains("--reduce-motion")
    struct Geometry: Codable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let opacity: Double
    }
    struct Sample: Codable {
        let time: Double
        let markers: [String: Geometry]
        let animations: [String]
        let rows: Int
        let selection: Int
        let table: String
        let focus: String
    }
    struct Phase: Codable {
        let name: String
        let samples: [Sample]
    }
    struct Report: Codable {
        let operatingSystem: String
        let reduceMotion: Bool
        let simpleDetail: Bool
        let phases: [Phase]
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor static func sample(_ host: NSView, start: Double) -> Sample {
        let views = descendants(host)
        let table = views.compactMap { $0 as? NSTableView }.first
        var markers: [String: Geometry] = [:]
        for marker in views.compactMap({ $0 as? SidebarProbeMarker.Marker }) {
            guard let layer = marker.layer else { continue }
            let presentation = layer.presentation() ?? layer
            let rect = presentation.convert(presentation.bounds, to: nil)
            var opacity: Float = 1
            var ancestor: CALayer? = presentation
            while let current = ancestor {
                opacity *= current.opacity
                ancestor = current.superlayer
            }
            markers[marker.key] = Geometry(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, opacity: Double(opacity))
        }
        let keys = table.map { descendants($0).flatMap { $0.layer?.animationKeys() ?? [] } } ?? []
        return Sample(time: ProcessInfo.processInfo.systemUptime - start, markers: markers,
            animations: Array(Set(keys)).sorted(), rows: table?.numberOfRows ?? -1,
            selection: table?.selectedRow ?? -1, table: table.map { String(describing: ObjectIdentifier($0)) } ?? "none",
            focus: host.window?.firstResponder.map { "\(type(of: $0))@\(ObjectIdentifier($0))" } ?? "none")
    }
    @MainActor static func measure(_ name: String, host: NSView,
                                   change: @escaping @MainActor () async throws -> Void) async throws -> Phase {
        let start = ProcessInfo.processInfo.systemUptime
        var samples = [sample(host, start: start)]
        let task = Task { try await change() }
        for _ in 0..<65 {
            try await Task.sleep(for: .milliseconds(10))
            samples.append(sample(host, start: start))
        }
        try await task.value
        // Include a final settled frame even if the mutation took longer than
        // the sampling window; slow/broken mutations must not pass as no-ops.
        try await Task.sleep(for: .milliseconds(150))
        samples.append(sample(host, start: start))
        let phase = Phase(name: name, samples: samples)
        let keys = Set(samples.flatMap { $0.markers.keys })
        let moving = keys.compactMap { key -> String? in
            let values = samples.compactMap { $0.markers[key] }
            let positions = Set(values.map { Int(($0.y * 10).rounded()) })
            let heights = Set(values.map { Int(($0.height * 10).rounded()) })
            let opacities = Set(values.map { Int(($0.opacity * 100).rounded()) })
            guard positions.count > 1 || heights.count > 1 || opacities.count > 1 else { return nil }
            return "\(key.prefix(6)) y=\(positions.count) h=\(heights.count) alpha=\(opacities.count)"
        }.sorted()
        let animatedSamples = samples.filter { !$0.animations.isEmpty }.count
        print("\(name): native animated samples=\(animatedSamples); \(Array(Set(moving)).sorted().joined(separator: "; ")); focus=\(samples.last!.focus)")
        try await Task.sleep(for: .milliseconds(150))
        return phase
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await run()
                app.stop(nil)
                app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
            } catch {
                print("PROBE ERROR: \(error)")
                exit(1)
            }
        }
        app.run()
    }
    /// Require several intermediate presentation values, not merely an animation
    /// key or correct endpoints. This intentionally rejects the original sidebar.
    static func failures(in report: Report) -> [String] {
        var failures: [String] = []
        let expected: [String: (rows: Int, children: Int)] = [
            "children-insert": (5, 3), "children-swap": (5, 3),
            "children-remove-one": (5, 2), "children-remove-all": (5, 0),
            "parent-insert-and-focus": (6, 0), "parent-move-and-echo": (6, 0),
            "parent-delete-and-focus": (5, 0), "parent-remote-swap": (5, 0),
            "children-during-content-echo": (5, 3), "parent-drop-rollback": (5, 3),
            "children-rapid-retarget": (5, 4), "metadata-only": (5, 4), "scroll-remount": (30, 4)]
        let tables = Set(report.phases.flatMap { $0.samples.map(\.table) })
        if tables.count != 1 || tables.contains("none") { failures.append("Native table identity changed or was missing") }
        for phase in report.phases {
            guard let before = phase.samples.first, let after = phase.samples.last else { continue }
            if phase.samples.contains(where: { $0.selection != -1 || $0.focus.contains("TableView") }) {
                failures.append("\(phase.name): native selection or keyboard focus changed")
            }
            let initial = Set(before.markers.keys), final = Set(after.markers.keys)
            guard let outcome = expected[phase.name] else { failures.append("Unknown phase: \(phase.name)"); continue }
            let groups = final.filter { $0.hasPrefix("group:") }.count
            if after.rows != outcome.rows || final.filter({ $0.hasPrefix("child:") }).count != outcome.children
                || groups == 0 || (phase.name != "scroll-remount" && groups != outcome.rows)
                || final.filter({ $0.hasPrefix("parent:") }).count != groups
                || final.filter({ $0.hasPrefix("footer:") }).count != groups {
                failures.append("\(phase.name): missing markers or incorrect final row/child counts")
            }
            if after.markers.values.contains(where: { $0.opacity < 0.98 || $0.height <= 0 || $0.width <= 0 }) {
                failures.append("\(phase.name): a settled row remained invisible or empty")
            }
            if phase.name.hasPrefix("children-"), !report.simpleDetail,
               (!before.focus.contains("FieldEditor") || after.focus != before.focus) {
                failures.append("\(phase.name): composer focus was not preserved")
            }
            if phase.name == "children-swap" || phase.name == "parent-remote-swap" || phase.name == "parent-move-and-echo" {
                let prefix = phase.name == "children-swap" ? "child:" : "group:"
                let moved = initial.intersection(final).filter { $0.hasPrefix(prefix) && abs(before.markers[$0]!.y - after.markers[$0]!.y) > 1 }
                if moved.count < 2 { failures.append("\(phase.name): expected reorder did not occur") }
            }
            let keys = Set(phase.samples.flatMap { $0.markers.keys })
            func values(_ key: String, _ property: KeyPath<Geometry, Double>) -> [Double] {
                phase.samples.compactMap { $0.markers[key]?[keyPath: property] }
            }
            func distinct(_ values: [Double]) -> Int { Set(values.map { Int(($0 * 100).rounded()) }).count }
            func requireMovement(_ key: String, _ property: KeyPath<Geometry, Double>) {
                guard let a = before.markers[key]?[keyPath: property], let b = after.markers[key]?[keyPath: property], abs(a - b) > 1 else { return }
                let intermediate = values(key, property).filter { $0 > min(a, b) + 0.1 && $0 < max(a, b) - 0.1 }
                if distinct(intermediate) < 3 { failures.append("\(phase.name): \(key.prefix(6)) snapped instead of moving") }
                let trajectory = phase.samples.compactMap { sample in sample.markers[key].map { (sample.time, $0[keyPath: property]) } }
                if zip(trajectory, trajectory.dropFirst()).contains(where: { pair in
                    pair.1.0 - pair.0.0 < 0.06 && abs(pair.1.1 - pair.0.1) > max(2, abs(b - a) * 0.6)
                }) { failures.append("\(phase.name): \(key.prefix(6)) jumped during its animation") }
            }
            if phase.name == "scroll-remount" {
                for key in keys where key.hasPrefix("child:") && values(key, \.opacity).contains(where: { $0 < 0.98 }) {
                    failures.append("Existing child replayed its insertion fade after scrolling")
                }
                continue
            }
            if phase.name == "parent-drop-rollback" {
                let returned = initial.filter { $0.hasPrefix("group:") && final.contains($0) }
                var excursions = 0
                for key in returned {
                    let positions = values(key, \.y), origin = before.markers[key]!.y
                    guard let peak = positions.indices.max(by: { abs(positions[$0] - origin) < abs(positions[$1] - origin) }),
                          abs(positions[peak] - origin) > 2 else { continue }
                    excursions += 1
                    if abs(positions.last! - origin) > 0.5 { failures.append("Rollback did not restore the original position") }
                    if !report.reduceMotion,
                       (distinct(Array(positions[...peak])) < 4 || distinct(Array(positions[peak...])) < 4) {
                        failures.append("Rollback snapped on an outgoing or returning leg")
                    }
                }
                if excursions < 2 { failures.append("Rollback did not exercise a pending reorder") }
            }
            if report.reduceMotion {
                if phase.samples.contains(where: { !$0.animations.isEmpty }) { failures.append("\(phase.name): native animation with Reduce Motion") }
                for key in keys {
                    if values(key, \.opacity).contains(where: { $0 > 0.02 && $0 < 0.98 }) {
                        failures.append("\(phase.name): opacity animation with Reduce Motion")
                    }
                    if !phase.name.contains("rapid"), !phase.name.contains("rollback"), distinct(values(key, \.y)) > 2 {
                        failures.append("\(phase.name): position animation with Reduce Motion")
                    }
                }
                continue
            }
            if phase.name == "metadata-only" {
                for key in keys where distinct(values(key, \.y)) > 1 || distinct(values(key, \.opacity)) > 1 {
                    failures.append("Metadata update restarted a row animation: \(key.prefix(6))")
                }
                continue
            }
            for key in initial.intersection(final) {
                requireMovement(key, \.y)
                if key.hasPrefix("group:") { requireMovement(key, \.height) }
            }
            for key in initial.symmetricDifference(final) where key.hasPrefix("child:") || key.hasPrefix("group:") {
                let opacity = values(key, \.opacity).filter { $0 > 0.02 && $0 < 0.98 }
                if distinct(opacity) < 3 { failures.append("\(phase.name): \(key.prefix(6)) appeared/disappeared without fading") }
            }
            // Child-only changes must leave the parent's title anchored, not
            // recenter it inside a row that already jumped to its final height.
            if phase.name.hasPrefix("children-"), phase.name != "children-swap" {
                for key in initial.intersection(final) where key.hasPrefix("parent:") {
                    let a = before.markers[key]!.y, b = after.markers[key]!.y
                    if abs(a - b) < 0.1, values(key, \.y).contains(where: { abs($0 - a) > 0.5 }) {
                        failures.append("\(phase.name): parent title moved during child resizing")
                    }
                }
            }
        }
        return failures
    }

    @MainActor static func run() async throws {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--analyze-report"), arguments.indices.contains(index + 1) {
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
            let report = try JSONDecoder().decode(Report.self, from: data)
            let issues = failures(in: report)
            print("\(issues.isEmpty ? "PASS" : "FAIL") saved report: \(issues.count) animation defects")
            for issue in issues { print("  \(issue)") }
            if arguments.contains("--check"), !issues.isEmpty { throw ExecError("Saved animation checks failed") }
            return
        }
        let suite = "exec-sidebar-probe-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(try JSONEncoder().encode([ChatModel(id: "deepseek/probe", name: "Probe")]), forKey: "chat.modelCatalog")
        let transport = SidebarProbeTransport()
        let parentIDs = (0..<5).map { _ in UUID() }
        let parents = parentIDs.enumerated().map { SidebarProbeTransport.snapshot($0.element, title: "Conversation \($0.offset + 1)") }
        let childIDs = (0..<3).map { _ in UUID() }
        let children = childIDs.enumerated().map {
            SidebarProbeTransport.snapshot($0.element, title: "Sub-agent \($0.offset + 1)", parent: parentIDs[0])
        }
        await transport.install(parents)
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
        defer { library.closePresentations() }
        try library.current.apply(parents[0].decoded(AgentSnapshot.self))
        try await library.refreshSharedState()
        let windows = SessionWindows(library: library)
        let simple = CommandLine.arguments.contains("--simple-detail")
        let host = NSHostingView(rootView: ProbeWindow(library: library, windows: windows, simpleDetail: simple))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 980, height: 700),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if arguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
        window.title = "Exec sidebar animation probe — synthetic data"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(800))
        if arguments.contains("--narrow"), let split = descendants(host).compactMap({ $0 as? NSSplitView }).first {
            split.setPosition(200, ofDividerAt: 0)
            try await Task.sleep(for: .milliseconds(300))
        }
        var phases: [Phase] = []
        phases.append(try await measure("children-insert", host: host) {
            await transport.install(parents + children)
            try await library.refreshSharedState()
        })
        phases.append(try await measure("children-swap", host: host) {
            await transport.reorder(parentIDs + childIDs.reversed())
            try await library.refreshSharedState()
        })
        phases.append(try await measure("children-remove-one", host: host) {
            await transport.install(parents + Array(children.prefix(2)))
            try await library.refreshSharedState()
        })
        phases.append(try await measure("children-remove-all", host: host) {
            await transport.install(parents)
            try await library.refreshSharedState()
        })
        phases.append(try await measure("parent-insert-and-focus", host: host) {
            library.newConversation()
            await library.current.waitForPendingSave()
        })
        phases.append(try await measure("parent-move-and-echo", host: host) {
            library.moveSidebarSessions(from: IndexSet(integer: 1), to: library.sidebarSessions.count)
        })
        phases.append(try await measure("parent-delete-and-focus", host: host) {
            if let id = library.currentSessionID { library.deleteSession(id) }
        })
        phases.append(try await measure("parent-remote-swap", host: host) {
            await transport.reorder(Array(library.sessionList.map(\.id).reversed()))
            try await library.refreshSharedState()
        })
        await transport.install(parents)
        try await library.refreshSharedState()
        try await Task.sleep(for: .milliseconds(400))
        phases.append(try await measure("children-during-content-echo", host: host) {
            await transport.install(parents + children)
            try await library.refreshSharedState()
            try await Task.sleep(for: .milliseconds(80))
            let changed = parentIDs.enumerated().map {
                SidebarProbeTransport.snapshot($0.element, title: "Conversation \($0.offset + 1)", activity: 2000)
            }
            await transport.install(changed + children)
            try await library.refreshSharedState()
        })
        phases.append(try await measure("parent-drop-rollback", host: host) {
            await transport.failOrder()
            library.moveSidebarSessions(from: IndexSet(integer: 0), to: library.sidebarSessions.count)
        })
        let extra = SidebarProbeTransport.snapshot(UUID(), title: "Another sub-agent", parent: parentIDs[0])
        phases.append(try await measure("children-rapid-retarget", host: host) {
            await transport.install(parents + Array(children.prefix(2)))
            try await library.refreshSharedState()
            try await Task.sleep(for: .milliseconds(80))
            await transport.install(parents + children + [extra])
            try await library.refreshSharedState()
        })
        phases.append(try await measure("metadata-only", host: host) {
            let changed = parentIDs.enumerated().map {
                SidebarProbeTransport.snapshot($0.element, title: "Conversation \($0.offset + 1)", activity: 3000)
            }
            await transport.install(changed + children + [extra])
            try await library.refreshSharedState()
        })
        let additional = (6...30).map { SidebarProbeTransport.snapshot(UUID(), title: "Conversation \($0)") }
        await transport.install(parents + additional + children + [extra])
        try await library.refreshSharedState()
        try await Task.sleep(for: .milliseconds(400))
        phases.append(try await measure("scroll-remount", host: host) {
            guard let table = descendants(host).compactMap({ $0 as? NSTableView }).first else {
                throw ExecError("Missing native sidebar table")
            }
            table.scrollRowToVisible(29)
            try await Task.sleep(for: .milliseconds(200))
            table.scrollRowToVisible(0)
        })
        let report = Report(operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                            reduceMotion: reduceMotion, simpleDetail: simple, phases: phases)
        let args = CommandLine.arguments
        let output = args.firstIndex(of: "--output").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            ?? ".build/sidebar-animation-report.json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: output))
        print("Report: \(output). Samples inspect owned view/layer geometry, not screenshots. Native drag gestures are not simulated.")
        let issues = failures(in: report)
        print("\(issues.isEmpty ? "PASS" : "FAIL"): \(phases.count) phases, \(issues.count) animation defects")
        for issue in issues { print("  \(issue)") }
        if args.contains("--check"), !issues.isEmpty { throw ExecError("Sidebar animation checks failed") }
    }
}
