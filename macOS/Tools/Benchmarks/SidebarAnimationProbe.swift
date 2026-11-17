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
        var duplicateMarkers: [String]? = nil
    }
    struct Mutation: Codable {
        let time: Double // Absolute uptime, aligned with Phase.startedAt.
        let inserted: [String]
        let removed: [String]
        let rows: Int
        let selection: UUID?
    }
    struct Phase: Codable {
        let name: String
        let samples: [Sample]
        var startedAt: Double? = nil
        var mutations: [Mutation]? = nil
        var peak: Sample? = nil
    }
    /// Keep targets near the top; catalog size stresses reconciliation, not offscreen fades.
    /// Repeated removals/reinsertions are intentional test input, never retries of a failed run.
    struct Stress: Codable {
        let cycles: Int
        let parents: Int
        let batch: Int
        let intervalMS: Int
        let kind: String
        let noise: Bool
        let reuseIDs: Bool

        init(_ arguments: [String]) throws {
            func number(_ flag: String, _ fallback: Int, _ range: ClosedRange<Int>) throws -> Int {
                guard let index = arguments.firstIndex(of: flag) else { return fallback }
                guard arguments.indices.contains(index + 1), let value = Int(arguments[index + 1]), range.contains(value) else {
                    throw ExecError("Invalid \(flag); expected \(range)")
                }
                return value
            }
            cycles = try number("--stress-cycles", 0, 1...1000)
            parents = try number("--stress-parents", 100, 5...2000)
            batch = try number("--stress-batch", 2, 1...3)
            intervalMS = try number("--stress-interval-ms", 80, 0...500)
            let index = arguments.firstIndex(of: "--stress-kind")
            kind = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "mixed"
            guard ["children", "parents", "mixed"].contains(kind) else { throw ExecError("Invalid --stress-kind") }
            noise = arguments.contains("--stress-noise")
            reuseIDs = arguments.contains("--stress-reuse-ids")
        }
    }
    struct Report: Codable {
        let operatingSystem: String
        let reduceMotion: Bool
        let simpleDetail: Bool
        let phases: [Phase]
        var stress: Stress? = nil
        var probeBuild: String? = nil
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor static func sample(_ host: NSView, start: Double) -> Sample {
        let views = descendants(host)
        let table = views.compactMap { $0 as? NSTableView }.first
        var markers: [String: Geometry] = [:]
        var duplicates: [String] = []
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
            if markers[marker.key] != nil { duplicates.append(marker.key) }
            markers[marker.key] = Geometry(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, opacity: Double(opacity))
        }
        let keys = table.map { descendants($0).flatMap { $0.layer?.animationKeys() ?? [] } } ?? []
        return Sample(time: ProcessInfo.processInfo.systemUptime - start, markers: markers,
            animations: Array(Set(keys)).sorted(), rows: table?.numberOfRows ?? -1,
            selection: table?.selectedRow ?? -1, table: table.map { String(describing: ObjectIdentifier($0)) } ?? "none",
            focus: host.window?.firstResponder.map { "\(type(of: $0))@\(ObjectIdentifier($0))" } ?? "none",
            duplicateMarkers: duplicates.sorted())
    }
    @MainActor static func measure(_ name: String, host: NSView,
                                   change: @escaping @MainActor () async throws -> Void) async throws -> Phase {
        let start = ProcessInfo.processInfo.systemUptime
        var samples = [sample(host, start: start)]
        var finished = false
        let task = Task { defer { finished = true }; try await change() }
        // Continue sampling long bursts instead of silently missing their tail.
        while samples.count < 66 || !finished {
            try await Task.sleep(for: .milliseconds(10))
            samples.append(sample(host, start: start))
        }
        try await task.value
        // Include a final settled frame even if the mutation took longer than
        // the sampling window; slow/broken mutations must not pass as no-ops.
        try await Task.sleep(for: .milliseconds(150))
        samples.append(sample(host, start: start))
        let phase = Phase(name: name, samples: samples, startedAt: start)
        if name.hasPrefix("stress-") { return phase }
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
            if phase.mutations != nil {
                failures += assessStress(phase, reduced: report.reduceMotion).issues.map { "\(phase.name): \($0)" }
                if !report.simpleDetail, !after.focus.contains("FieldEditor") {
                    failures.append("\(phase.name): composer focus was not restored")
                }
                continue
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

    /// Per-mutation windows catch transient rows that endpoint-only checks miss.
    /// Fewer than six samples / 80 ms is inconclusive, not a missing-fade verdict.
    /// Markers measure inherited layer opacity/geometry, not rendered pixels or GPU cadence.
    /// They can extend outside clipping bounds; this is not proof of visible text fading.
    /// Focus noise deliberately blurs the window; its recovery check is a separate
    /// synthetic assertion, not evidence that an ordinary deletion loses focus.
    static func assessStress(_ phase: Phase, reduced: Bool) -> (issues: [String], checked: Int, short: Int, unseen: Int) {
        guard let mutations = phase.mutations, let start = phase.startedAt,
              let before = phase.samples.first, let after = phase.samples.last, let peak = phase.peak else {
            return (["Missing stress evidence"], 0, 0, 0)
        }
        var issues: [String] = []
        var checked = 0, short = 0, unseen = 0
        func distinct(_ values: [Double]) -> Int { Set(values.map { Int(($0 * 100).rounded()) }).count }
        if after.rows != mutations.last?.rows || after.markers.keys.contains(where: { $0.hasPrefix("child:") }) {
            issues.append("incorrect settled parent/child counts")
        }
        let targets = Set(mutations.flatMap(\.inserted))
        if !targets.isSubset(of: Set(peak.markers.keys)) { issues.append("inserted targets missing at settled peak") }
        for frame in [peak, after] {
            if frame.markers.values.contains(where: { $0.opacity < 0.98 || $0.height <= 0 || $0.width <= 0 }) {
                issues.append("settled content invisible or empty")
            }
        }
        for (index, mutation) in mutations.enumerated() {
            for (inserting, keys) in [(true, mutation.inserted), (false, mutation.removed)] {
                for key in keys {
                    let end = mutations.dropFirst(index + 1).first { $0.inserted.contains(key) || $0.removed.contains(key) }?.time
                        ?? (after.time + start)
                    let frames = phase.samples.filter { $0.time + start >= mutation.time && $0.time + start < end }
                    // Include the last pre-mutation frame: native List can reset
                    // to model opacity before the first post-mutation sample.
                    let preceding = phase.samples.last { $0.time + start < mutation.time }
                    let boundaryFrames = preceding.map { [$0] + frames } ?? frames
                    if boundaryFrames.contains(where: { $0.duplicateMarkers?.contains(key) == true }) {
                        issues.append("mutation \(index) \(key): ambiguous duplicate presentation markers")
                        continue
                    }
                    let opacity = frames.compactMap { $0.markers[key]?.opacity }
                    if opacity.isEmpty { unseen += 1; continue }
                    let partial = opacity.filter { $0 > 0.02 && $0 < 0.98 }
                    // Two adjacent samples can prove an abrupt reset even when
                    // the interrupted window is too short to assess a full fade.
                    if !reduced {
                        let jumped = zip(boundaryFrames, boundaryFrames.dropFirst()).contains { a, b in
                            guard b.time - a.time < 0.06, let x = a.markers[key]?.opacity,
                                  let y = b.markers[key]?.opacity else { return false }
                            return abs(y - x) > 0.6
                        }
                        if jumped { issues.append("mutation \(index) \(key): opacity jumped by >0.6 within 60ms") }
                    }
                    if reduced, !partial.isEmpty { issues.append("mutation \(index) \(key): fade with Reduce Motion") }
                    if end - mutation.time < 0.08 || frames.count < 6 { short += 1; continue }
                    checked += 1
                    if !reduced, distinct(partial) < 3 {
                        let near = phase.samples.filter { $0.time + start >= mutation.time - 0.06 && $0.time + start < end }
                        let gap = zip(near, near.dropFirst()).contains { a, b in
                            b.time - a.time > 0.06 && abs((a.markers[key]?.opacity ?? 0) - (b.markers[key]?.opacity ?? 0)) > 0.02
                        }
                        issues.append("mutation \(index) \(key): \(inserting ? "insertion" : "removal") \(gap ? "undersampled" : "lacks sampled fade") (\(distinct(partial)) intermediate values)")
                    }
                }
            }
        }
        // Settled legs also check retained neighbors and row height. Retargeted
        // paths need not be monotonic; do not mistake their reversals for jumps.
        for (a, b) in [(before, peak), (peak, after)] {
            let frames = phase.samples.filter { $0.time >= a.time && $0.time <= b.time }
            for key in Set(a.markers.keys).intersection(b.markers.keys) {
                for property in [\Geometry.y, \Geometry.height] {
                    let origin = a.markers[key]![keyPath: property], destination = b.markers[key]![keyPath: property]
                    guard abs(origin - destination) > 1 else { continue }
                    let values = frames.compactMap { $0.markers[key]?[keyPath: property] }
                    let intermediate = values.filter { $0 > min(origin, destination) + 0.1 && $0 < max(origin, destination) - 0.1 }
                    if !reduced, distinct(intermediate) < 3 {
                        let trajectory = frames.compactMap { frame in frame.markers[key].map { (frame.time, $0[keyPath: property]) } }
                        let gap = zip(trajectory, trajectory.dropFirst()).contains { a, b in b.0 - a.0 > 0.06 && abs(b.1 - a.1) > 1 }
                        issues.append("\(key): retained geometry \(gap ? "undersampled" : "snapped")")
                    }
                }
            }
        }
        if reduced, phase.samples.contains(where: { !$0.animations.isEmpty }) { issues.append("native animation with Reduce Motion") }
        return (issues, checked, short, unseen)
    }

    static func printIssues(_ issues: [String], report: Report) {
        let gapsInEvidence = issues.filter { $0.contains("undersampled") || $0.contains("ambiguous") }.count
        print("Checks: \(issues.count - gapsInEvidence) observed failures; \(gapsInEvidence) sampling-limited failures (not proof of a snap/missing fade)")
        for issue in issues.prefix(24) { print("  \(issue)") }
        if issues.count > 24 { print("  ... \(issues.count - 24) more; analyze saved JSON for complete per-mutation evidence") }
        let phases = report.phases.filter { $0.mutations != nil }
        guard !phases.isEmpty else { return }
        let coverage = phases.map { assessStress($0, reduced: report.reduceMotion) }
        let mutations = phases.flatMap { $0.mutations ?? [] }
        let gaps = phases.flatMap { phase in zip(phase.samples, phase.samples.dropFirst()).map { $1.time - $0.time } }
        let failed = phases.filter { phase in issues.contains { $0.hasPrefix("\(phase.name):") } }.count
        print("Stress: \(phases.count) cycles; \(mutations.filter { !$0.inserted.isEmpty || !$0.removed.isEmpty }.count) structural snapshots; \(mutations.flatMap(\.inserted).count) insertions / \(mutations.flatMap(\.removed).count) removals")
        print("Fade windows: checked=\(coverage.reduce(0) { $0 + $1.checked }), short=\(coverage.reduce(0) { $0 + $1.short }), unobserved=\(coverage.reduce(0) { $0 + $1.unseen }); failed cycles=\(failed); max sample gap=\(String(format: "%.3f", gaps.max() ?? 0))s")
        let duplicateFrames = phases.flatMap(\.samples).filter { !($0.duplicateMarkers ?? []).isEmpty }.count
        let multiplicityRecorded = phases.flatMap(\.samples).allSatisfy { $0.duplicateMarkers != nil }
        print("Ambiguous marker frames: \(duplicateFrames)\(multiplicityRecorded ? "" : " (older report may not record duplicates)"). Short/unobserved windows do not establish smoothness; counts are synthetic catalog mutations, not user clicks or backend creates.")
    }

    @MainActor private static func stressPhases(_ stress: Stress, host: NSView, library: ChatLibrary,
                                        transport: SidebarProbeTransport) async throws -> [Phase] {
        let roots = (0..<stress.parents).map { _ in UUID() }
        let stableParents = (0..<stress.batch).map { _ in UUID() }
        let stableChildren = (0..<stress.batch).map { _ in UUID() }
        var tick = 0
        func snapshots(_ parents: [UUID], _ children: [UUID]) -> [AgentJSON] {
            (parents + roots).enumerated().map {
                SidebarProbeTransport.snapshot($0.element, title: "Stress conversation \($0.offset + 1)", activity: Double(1000 + tick))
            } + children.enumerated().map {
                SidebarProbeTransport.snapshot($0.element, title: "Stress child \($0.offset + 1)", parent: roots[0], activity: Double(1000 + tick))
            }
        }
        await transport.install(snapshots([], []))
        try await library.refreshSharedState()
        library.openSession(roots[0])
        await library.waitForNavigation()
        try await Task.sleep(for: .milliseconds(600))
        var phases: [Phase] = []
        print("Stress configuration: cycles=\(stress.cycles), parents=\(stress.parents), batch=\(stress.batch), interval=\(stress.intervalMS)ms, kind=\(stress.kind), noise=\(stress.noise), reuseIDs=\(stress.reuseIDs)")
        for cycle in 0..<stress.cycles {
            let parents = stress.kind == "children" ? [] : (stress.reuseIDs ? stableParents : stableParents.map { _ in UUID() })
            let children = stress.kind == "parents" ? [] : (stress.reuseIDs ? stableChildren : stableChildren.map { _ in UUID() })
            var currentParents: [UUID] = [], currentChildren: [UUID] = []
            var mutations: [Mutation] = []
            var peak: Sample?
            func install(_ parents: [UUID], _ children: [UUID]) async throws {
                let old = Set(currentParents.map { "group:\($0)" } + currentChildren.map { "child:\($0)" })
                let new = Set(parents.map { "group:\($0)" } + children.map { "child:\($0)" })
                await transport.install(snapshots(parents, children))
                try await library.refreshSharedState()
                currentParents = parents; currentChildren = children
                mutations.append(Mutation(time: ProcessInfo.processInfo.systemUptime,
                    inserted: new.subtracting(old).sorted(), removed: old.subtracting(new).sorted(),
                    rows: stress.parents + parents.count, selection: library.sidebarSelectionID))
            }
            func interleave(_ step: Int) async throws {
                try await Task.sleep(for: .milliseconds(stress.intervalMS / 2))
                if stress.noise {
                    tick += 1 // Same geometry, new activity metadata; not a structural change.
                    try await install(currentParents, currentChildren)
                    if step.isMultiple(of: 2) { host.window?.makeFirstResponder(nil) }
                    let selected = roots[(cycle + step) % 2]
                    library.openSession(selected)
                    await library.waitForNavigation()
                    guard library.sidebarSelectionID == selected else { throw ExecError("Stress selection did not apply") }
                    mutations.append(Mutation(time: ProcessInfo.processInfo.systemUptime, inserted: [], removed: [],
                        rows: stress.parents + currentParents.count, selection: selected))
                }
                try await Task.sleep(for: .milliseconds(stress.intervalMS - stress.intervalMS / 2))
            }
            var phase = try await measure("stress-\(stress.kind)-\(cycle + 1)", host: host) {
                try await install(parents, children)
                try await interleave(0)
                try await install(Array(parents.dropFirst()), Array(children.dropFirst()))
                try await interleave(1)
                try await install(parents, children) // Return while removal is still in flight.
                try await interleave(2)
                try await Task.sleep(for: .milliseconds(350))
                peak = sample(host, start: 0)
                try await install(Array(parents.dropFirst()), Array(children.dropFirst()))
                try await interleave(3)
                try await install([], [])
                try await interleave(4)
                try await Task.sleep(for: .milliseconds(350))
            }
            phase.mutations = mutations
            if let peak, let start = phase.startedAt {
                phase.peak = Sample(time: peak.time - start, markers: peak.markers, animations: peak.animations,
                                    rows: peak.rows, selection: peak.selection, table: peak.table, focus: peak.focus,
                                    duplicateMarkers: peak.duplicateMarkers)
            }
            phases.append(phase)
            if (cycle + 1).isMultiple(of: 25) || cycle + 1 == stress.cycles { print("Stress sampled \(cycle + 1)/\(stress.cycles) cycles") }
        }
        return phases
    }

    @MainActor static func run() async throws {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--analyze-report"), arguments.indices.contains(index + 1) {
            let data = try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
            let report = try JSONDecoder().decode(Report.self, from: data)
            let issues = failures(in: report)
            print("\(issues.isEmpty ? "PASS" : "FAIL") saved report: \(issues.count) check failures")
            printIssues(issues, report: report)
            if arguments.contains("--check"), !issues.isEmpty { throw ExecError("Saved animation checks failed") }
            return
        }
        let stress = try Stress(arguments)
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
        if stress.cycles > 0 {
            phases = try await stressPhases(stress, host: host, library: library, transport: transport)
        } else {
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
        }
        let report = Report(operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                            reduceMotion: reduceMotion, simpleDetail: simple, phases: phases,
                            stress: stress.cycles > 0 ? stress : nil,
                            probeBuild: try? String(contentsOfFile: ".build/sidebar-animation-probe.sources", encoding: .utf8))
        let args = CommandLine.arguments
        let output = args.firstIndex(of: "--output").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            ?? ".build/sidebar-animation-report.json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = stress.cycles > 0 ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: output))
        print("Report: \(output). Samples inspect owned view/layer geometry, not screenshots. Native drag gestures are not simulated.")
        let issues = failures(in: report)
        print("\(issues.isEmpty ? "PASS" : "FAIL"): \(phases.count) phases, \(issues.count) check failures")
        printIssues(issues, report: report)
        if args.contains("--check"), !issues.isEmpty { throw ExecError("Sidebar animation checks failed") }
    }
}
