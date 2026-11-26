import AppKit
import SwiftUI
import CryptoKit

private struct PollingEvent: Codable, Sendable {
    let time: Double // Uptime, like Phase.startedAt; response evidence, not UI application time.
    let kind: String
    let stage: Int
    let session: UUID?
    let messages: Int
    let bytes: Int
}

private extension AgentJSON {
    func probeSetting(_ key: String, _ value: AgentJSON) -> AgentJSON {
        guard case .object(var object) = self else { preconditionFailure("Expected synthetic object") }
        object[key] = value
        return .object(object)
    }
}

/// Only synthetic snapshots are served. No sockets, accounts, Keychain or inference.
private actor SidebarProbeTransport: AgentTransport {
    var snapshots: [UUID: AgentJSON] = [:]
    var order: [UUID] = []
    var failNextOrder = false
    var rejected: [String] = []
    var evidence: [PollingEvent] = []
    private var pollingRoots: [UUID] = []
    private var pollingChildren: [AgentJSON] = []
    private var prefixes: [UUID: String] = [:]
    private var remainingCatalogPolls = 0
    private var stage = 0
    private var pendingTitle = false
    private var appendOnTitle = false
    private var tick = 0
    private var changeRevision = 0
    private var changeStreams: [UUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private func changeNotice() -> Data {
        try! JSONEncoder().encode(RemoteChangeNotification(epoch: "sidebar-probe", catalog: "\(changeRevision)",
            conversations: Dictionary(uniqueKeysWithValues: order.map { ($0.uuidString.lowercased(), "\(changeRevision)") })))
    }
    private func subscribeChanges(_ id: UUID, _ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        changeStreams[id] = continuation
        continuation.yield(changeNotice())
    }
    private func removeChanges(_ id: UUID) { changeStreams[id] = nil }
    func autoTitle(_ id: UUID) throws {
        guard let snapshot = snapshots[id] else { throw ExecError("Missing fresh synthetic conversation") }
        snapshots[id] = snapshot.probeSetting("metadata", snapshot["metadata"]
            .probeSetting("title", .string(Self.longTitle)).probeSetting("manuallyNamed", .bool(false)))
        changeRevision += 1
        evidence.append(PollingEvent(time: ProcessInfo.processInfo.systemUptime, kind: "auto-title-ready", stage: changeRevision,
            session: id, messages: 0, bytes: 0))
        for stream in changeStreams.values { stream.yield(changeNotice()) }
    }
    nonisolated static let longTitle = "Review concurrent workspace changes and summarize the delegated implementation results"

    func install(_ values: [AgentJSON]) {
        snapshots = Dictionary(uniqueKeysWithValues: values.map { (UUID(uuidString: $0["id"].string!)!, $0) })
        order = values.map { UUID(uuidString: $0["id"].string!)! }
    }
    func reorder(_ ids: [UUID]) { order = ids }
    func failOrder() { failNextOrder = true }
    func reject(_ method: String, _ path: String) -> ExecError {
        let message = "Unexpected probe request: \(method) \(path)"
        rejected.append(message)
        return ExecError(message)
    }

    // Generate history off the main actor. Only the final streaming message changes;
    // immutable prefixes support real 32-message backfill and overlapping suffix reads.
    func configurePolling(messages count: Int, roots: [UUID], children: [AgentJSON], append: Bool) throws {
        appendOnTitle = append
        pollingRoots = Array(roots.prefix(2))
        pollingChildren = children
        let paragraph = "Synthetic workspace analysis: preserve cancellation, stable identity, and conversation integrity.\n\n- Inspect the current implementation.\n- Verify the concurrent update.\n\n```swift\nlet result = values.map { $0 + 1 }\n```\n\n"
        for id in pollingRoots {
            let messages: [AgentJSON] = (0..<count).map { index in
                .object(["id": .string(UUID().uuidString.lowercased()),
                    "role": .string(index.isMultiple(of: 2) ? "user" : "assistant"),
                    "text": .string("Message \(index + 1)\n\n" + String(repeating: paragraph, count: 8)),
                    "status": .string(index == count - 1 ? "streaming" : "complete")])
            }
            let data = try JSONEncoder().encode(Array(messages.dropLast()))
            prefixes[id] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            snapshots[id] = snapshots[id]!
                .probeSetting("messages", .array(messages))
                .probeSetting("operation", .object(["id": .string(UUID().uuidString), "state": .string("running")]))
        }
    }
    func armPollingCycle() { remainingCatalogPolls = 2 }
    private func advanceCatalog() {
        guard remainingCatalogPolls > 0 else { return }
        remainingCatalogPolls -= 1
        stage += 1
        for child in pollingChildren {
            let id = UUID(uuidString: child["id"].string!)!
            order.removeAll { $0 == id }
            snapshots[id] = stage.isMultiple(of: 2) ? nil : child
            if !stage.isMultiple(of: 2) { order.append(id) }
        }
        // The next natural 200ms reader poll delivers a geometry-changing title
        // while the 250ms child animation is in flight. No injected main-thread stall.
        pendingTitle = true
    }
    private func sync(_ id: UUID, query: String?) throws -> (AgentJSON, String) {
        var snapshot = snapshots[id]!
        var messages = snapshot["messages"].array
        let total = messages.count
        let offset: Int, end: Int, reset: Bool, kind: String
        if let query {
            let fields = query.split(separator: "&").map(String.init)
            if fields.count == 1, fields[0].hasPrefix("before="),
               let index = messages.firstIndex(where: { $0["id"].string == String(fields[0].dropFirst(7)) }), index > 0 {
                offset = max(0, index - 32); end = index; reset = false; kind = "sync-before"
            } else if fields.count == 2, fields[0].hasPrefix("after="), fields[1] == "prefix=\(prefixes[id] ?? "")",
                      let index = messages.firstIndex(where: { $0["id"].string == String(fields[0].dropFirst(6)) }), index == total - 1 {
                offset = index; end = total; reset = false; kind = "sync-after"
                tick += 1
                messages[index] = messages[index].probeSetting("text", .string(messages[index]["text"].string! + "\nSynthetic progress \(tick)."))
                if id == pollingRoots.first, pendingTitle {
                    pendingTitle = false
                    snapshot = snapshot.probeSetting("metadata", snapshot["metadata"].probeSetting("title",
                        .string(stage.isMultiple(of: 2) ? "Conversation 1" : Self.longTitle)))
                    evidence.append(PollingEvent(time: ProcessInfo.processInfo.systemUptime, kind: "title", stage: stage,
                        session: id, messages: total, bytes: 0))
                    if appendOnTitle {
                        messages[index] = messages[index].probeSetting("status", .string("complete"))
                        messages.append(.object(["id": .string(UUID().uuidString.lowercased()), "role": .string("assistant"),
                            "text": .string("Synthetic delegation result \(stage)."), "status": .string("streaming")]))
                        let data = try JSONEncoder().encode(Array(messages.dropLast()))
                        prefixes[id] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        evidence.append(PollingEvent(time: ProcessInfo.processInfo.systemUptime, kind: "append", stage: stage,
                            session: id, messages: messages.count, bytes: 0))
                    }
                }
                snapshot = snapshot.probeSetting("messages", .array(messages))
                snapshots[id] = snapshot
            } else { throw reject("GET", "invalid synthetic sync cursor") }
        } else {
            offset = max(0, total - 32); end = total; reset = true; kind = "sync-initial"
        }
        let responseEnd = kind == "sync-after" ? messages.count : end
        return (.object(["snapshot": snapshot.probeSetting("messages", .array(Array(messages[offset..<responseEnd]))),
            "offset": .number(Double(offset)), "total": .number(Double(messages.count)), "reset": .bool(reset),
            "prefix": prefixes[id].map(AgentJSON.string) ?? .null]), kind)
    }
    func request(_ method: String, _ path: String, body: Data?) async throws -> Data {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let route = String(parts[0]), query = parts.count == 2 ? String(parts[1]) : nil
        let result: AgentJSON
        var kind: String?, session: UUID?
        if route == "/v1/library", query == nil, method == "GET" || method == "PATCH" {
            if method == "PATCH" {
                guard let body else { throw reject(method, path) }
                // Legacy reorder echo only; not used to synthesize polling workload.
                try await Task.sleep(for: .milliseconds(80))
                if failNextOrder { failNextOrder = false; throw ExecError("Synthetic reorder failure") }
                let patch = try JSONDecoder().decode(AgentJSON.self, from: body)
                if case .array(let ids) = patch["order"] { order = ids.compactMap { $0.string.flatMap(UUID.init(uuidString:)) } }
            }
            var configuration = AgentLibraryConfiguration()
            configuration.order = order
            return try JSONEncoder().encode(configuration)
        } else if route == "/v1/conversations", query == nil, method == "GET" {
            advanceCatalog()
            // Real catalog responses contain summaries, not the heavy history.
            result = .array(order.compactMap { snapshots[$0]?.probeSetting("messages", .array([])) })
            kind = "catalog"
        } else if route == "/v1/conversations", query == nil, method == "POST", let body {
            let create = try JSONDecoder().decode(AgentJSON.self, from: body)
            guard let workspace = create["workspace"].string else { throw reject(method, path) }
            result = Self.snapshot(UUID(), title: "New conversation").probeSetting("workspace", .string(workspace))
            let id = UUID(uuidString: result["id"].string!)!
            snapshots[id] = result
            order.insert(id, at: 0)
        } else {
            let pieces = route.split(separator: "/")
            guard (pieces.count == 3 || pieces.count == 4), pieces[0] == "v1", pieces[1] == "conversations",
                  let id = UUID(uuidString: String(pieces[2])), let snapshot = snapshots[id] else { throw reject(method, path) }
            session = id
            if pieces.count == 3, query == nil, method == "DELETE" {
                snapshots[id] = nil
                order.removeAll { $0 == id }
                result = .object([:])
            } else if pieces.count == 4, pieces[3] == "sync", method == "GET" {
                (result, kind) = try sync(id, query: query)
            } else if pieces.count == 3, query == nil, method == "GET" {
                result = snapshot
            } else { throw reject(method, path) }
        }
        let data = try JSONEncoder().encode(result)
        if let kind {
            evidence.append(PollingEvent(time: ProcessInfo.processInfo.systemUptime, kind: kind, stage: stage,
                session: session, messages: result["snapshot"]["messages"].array.count, bytes: data.count))
        }
        return data
    }
    nonisolated func events(_ method: String, _ path: String, body: Data?) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            if method == "GET", path == "/v1/changes", body == nil {
                if CommandLine.arguments.contains("--fresh-title-events") {
                    let id = UUID()
                    continuation.onTermination = { _ in Task { await self.removeChanges(id) } }
                    Task { await self.subscribeChanges(id, continuation) }
                } else {
                    // Exercise legacy polling unless the fresh-session case requests
                    // production notification-driven readers and background catalog refresh.
                    continuation.finish(throwing: AgentHTTPError(status: 404, message: "Synthetic polling backend"))
                }
            } else {
                Task { continuation.finish(throwing: await self.reject(method, path)) }
            }
        }
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

/// Capture the real List callback in the generated copy. Calling it exercises
/// drop reconciliation, not AppKit's pointer tracking or drag preview.
@MainActor enum SidebarProbeMove {
    private static var drop: ((IndexSet, Int) -> Void)?

    static func capture(_ action: @escaping (IndexSet, Int) -> Void) -> (IndexSet, Int) -> Void {
        drop = action
        return action
    }

    static func perform(from offsets: IndexSet, to destination: Int, library: ChatLibrary) throws {
        if CommandLine.arguments.contains("--native-list-control") {
            library.moveSidebarSessions(from: offsets, to: destination)
        } else if let drop {
            drop(offsets, destination)
        } else {
            throw ExecError("The sidebar did not register its drop callback")
        }
    }
}

/// A deliberately small native List control: no family height, child appearance,
/// composer, selection, or production row modifiers. Same synthetic catalog/transactions.
private struct SidebarNativeListControl: View {
    let library: ChatLibrary
    @State private var rows: [SessionSummary] = []
    var body: some View {
        List {
            ForEach(rows) { row in
                Text(row.title).lineLimit(2)
                    .frame(height: CommandLine.arguments.contains("--native-natural-height") ? nil : 43)
                    .background(SidebarProbeMarker(id: row.id, role: "group"))
            }
        }
        .listStyle(.sidebar)
        .onChange(of: library.sidebarSessions, initial: true) { _, updated in
            withAnimation(SidebarAnimationProbe.reduceMotion ||
                          (rows.map(\.id) == updated.map(\.id) && !CommandLine.arguments.contains("--native-animated-metadata"))
                          ? nil : .easeInOut(duration: 0.25)) { rows = updated }
        }
    }
}

private struct ProbeWindow: View {
    let library: ChatLibrary
    let windows: SessionWindows
    let simpleDetail: Bool
    var body: some View {
        ChatWindowLayout(initiallyShowsSidebar: !CommandLine.arguments.contains("--reveal-sidebar"),
                         sidebarRevealRequest: windows.sidebarRevealRequest) {
            if CommandLine.arguments.contains("--native-list-control") {
                SidebarNativeListControl(library: library)
            } else {
                SessionSidebar(store: library, open: windows.openSession, delete: { library.deleteSession($0.id) })
            }
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
        var top: Double { y + height } // Layer coordinates are bottom-up.
    }
    // Opt-in ownership evidence. IDs are process-local, not stable across runs.
    struct AnimationTrace: Codable {
        let key: String
        let kind: String
        let keyPath: String?
        let begin: Double
        let duration: Double
        let from: String?
        let to: String?
        let by: String?
        let additive: Bool
    }
    struct LayerTrace: Codable {
        let id: String
        let kind: String
        let parent: String?
        let presentationParent: String?
        let modelOpacity: Float
        let opacity: Float
        let modelPosition: String
        let position: String
        let modelBounds: String?
        let bounds: String?
        let localTime: Double?
        let animations: [AnimationTrace]
    }
    struct OwnerTrace: Codable {
        let key: String
        let marker: String
        let attached: Bool
        let views: [String]
        let layers: [LayerTrace]
    }
    @MainActor static func ownerTrace(_ marker: SidebarProbeMarker.Marker, attached: Bool) -> OwnerTrace {
        func identity(_ object: AnyObject) -> String { String(describing: ObjectIdentifier(object)) }
        var views: [String] = []
        var view: NSView? = marker
        while let current = view {
            views.append("\(type(of: current))@\(identity(current)) layer=\(current.layer.map(identity) ?? "none")")
            view = current.superview
        }
        var layers: [LayerTrace] = []
        var layer = marker.layer
        while let current = layer {
            let presentation = current.presentation() ?? current
            let animations = (current.animationKeys() ?? []).sorted().compactMap { key -> AnimationTrace? in
                guard let animation = current.animation(forKey: key) else { return nil }
                let basic = animation as? CABasicAnimation
                let property = animation as? CAPropertyAnimation
                return AnimationTrace(key: key, kind: String(describing: type(of: animation)),
                    keyPath: property?.keyPath, begin: animation.beginTime, duration: animation.duration,
                    from: basic?.fromValue.map { String(describing: $0) },
                    to: basic?.toValue.map { String(describing: $0) },
                    by: basic?.byValue.map { String(describing: $0) }, additive: property?.isAdditive ?? false)
            }
            layers.append(LayerTrace(id: identity(current), kind: String(describing: type(of: current)),
                parent: current.superlayer.map(identity), presentationParent: presentation.superlayer.map { identity($0.model()) },
                modelOpacity: current.opacity, opacity: presentation.opacity,
                modelPosition: NSStringFromPoint(current.position), position: NSStringFromPoint(presentation.position),
                modelBounds: NSStringFromRect(current.bounds), bounds: NSStringFromRect(presentation.bounds),
                localTime: current.convertTime(CACurrentMediaTime(), from: nil), animations: animations))
            layer = current.superlayer
        }
        return OwnerTrace(key: marker.key, marker: identity(marker), attached: attached, views: views, layers: layers)
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
        var detachedMarkers: [String]? = nil
        var composerFocused: Bool? = nil
        var owners: [OwnerTrace]? = nil
        var hasComposerFocus: Bool { composerFocused ?? focus.hasPrefix("Editor@") }
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
    struct Polling: Codable {
        let cycles: Int
        let messages: Int
        let navigate: Bool
        var append: Bool? // Optional so historical reports remain readable.
        init(_ arguments: [String]) throws {
            func number(_ flag: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
                guard let index = arguments.firstIndex(of: flag) else { return fallback }
                guard arguments.indices.contains(index + 1), let value = Int(arguments[index + 1]), range.contains(value) else {
                    throw ExecError("Invalid \(flag); expected \(range)")
                }
                return value
            }
            cycles = try number("--polling-cycles", fallback: 0, range: 1...20)
            messages = try number("--polling-messages", fallback: 240, range: 66...1000)
            navigate = arguments.contains("--polling-navigate")
            append = arguments.contains("--polling-append")
            guard messages.isMultiple(of: 2) else { throw ExecError("--polling-messages must be even (assistant tail)") }
        }
    }
    struct Report: Codable {
        let operatingSystem: String
        let reduceMotion: Bool
        let simpleDetail: Bool
        let phases: [Phase]
        var stress: Stress? = nil
        var polling: Polling? = nil
        fileprivate var pollingEvidence: [PollingEvent]? = nil
        var rejectedRoutes: [String]? = nil
        var probeBuild: String? = nil
        var lifecycleOptions: [String]? = nil
        var hiddenReveal: Sample? = nil
        var arguments: [String]? = nil
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor static func sample(_ host: NSView, start: Double) -> Sample {
        let views = descendants(host)
        let table = views.compactMap { $0 as? NSTableView }.first
        var markers: [String: Geometry] = [:]
        var duplicates: [String] = [], detached: [String] = []
        let traceOwners = CommandLine.arguments.contains("--trace-owners")
        var owners: [OwnerTrace] = []
        for marker in views.compactMap({ $0 as? SidebarProbeMarker.Marker }) {
            guard let layer = marker.layer else { continue }
            let presentation = layer.presentation() ?? layer
            var opacity: Float = 1
            var attached = false
            var ancestor: CALayer? = presentation
            while let current = ancestor {
                if current.model() === host.layer { attached = true }
                opacity *= current.opacity
                ancestor = current.superlayer
            }
            // AppKit can retain fitting-size/recycled views in the NSView tree
            // while their layers are detached. Converting those to nil yields
            // row-local coordinates, not an actual frame in the window.
            if traceOwners, marker.key.hasPrefix("group:") {
                owners.append(ownerTrace(marker, attached: attached))
            }
            guard attached else { detached.append(marker.key); continue }
            let rect = presentation.convert(presentation.bounds, to: nil)
            if markers[marker.key] != nil { duplicates.append(marker.key) }
            markers[marker.key] = Geometry(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height, opacity: Double(opacity))
        }
        let keys = table.map { descendants($0).flatMap { $0.layer?.animationKeys() ?? [] } } ?? []
        return Sample(time: ProcessInfo.processInfo.systemUptime - start, markers: markers,
            animations: Array(Set(keys)).sorted(), rows: table?.numberOfRows ?? -1,
            selection: table?.selectedRow ?? -1, table: table.map { String(describing: ObjectIdentifier($0)) } ?? "none",
            focus: host.window?.firstResponder.map { "\(type(of: $0))@\(ObjectIdentifier($0))" } ?? "none",
            duplicateMarkers: duplicates.sorted(), detachedMarkers: detached.sorted(),
            composerFocused: host.window?.firstResponder is ComposerTextInput.Editor,
            owners: traceOwners ? owners : nil)
    }
    @MainActor static func toggleSidebar(_ host: NSView, visible: Bool) async throws {
        guard let split = descendants(host).compactMap({ $0 as? NSSplitView }).first,
              let controller = split.delegate as? NSSplitViewController,
              let sidebar = controller.splitViewItems.first(where: { $0.behavior == .sidebar }),
              sidebar.isCollapsed == visible else { throw ExecError("Unexpected sidebar visibility before toggle") }
        controller.toggleSidebar(nil)
        try await Task.sleep(for: .milliseconds(600))
        guard sidebar.isCollapsed != visible else { throw ExecError("Sidebar toggle did not settle") }
    }

    @MainActor static func measure(_ name: String, host: NSView,
                                   change: @escaping @MainActor () async throws -> Void) async throws -> Phase {
        if CommandLine.arguments.contains("--cycle-sidebar") {
            try await toggleSidebar(host, visible: false)
            try await toggleSidebar(host, visible: true)
        }
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
        // Keep sampling through settlement; a deliberate 150ms gap would pollute
        // the workload's maximum sampling-gap metric and hide late transitions.
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(10))
            samples.append(sample(host, start: start))
        }
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
    /// Geometry thresholds alone can miss a late native clip retirement. With
    /// ownership tracing, reject loss of an unfinished fade even across a detached
    /// sample. This proves owner loss, not composited pixels during detachment.
    static func ownerFailures(_ phase: Phase) -> [String] {
        var fading: [String: (key: String, layer: LayerTrace, time: Double)] = [:]
        var issues: [String] = []
        for sample in phase.samples {
            for owner in sample.owners ?? [] where owner.attached {
                if let previous = fading[owner.marker] {
                    let clock = previous.layer.localTime ?? ((phase.startedAt ?? 0) + previous.time)
                    let animation = previous.layer.animations.first { $0.keyPath == "opacity" }
                    let remaining = (animation.map { $0.begin + $0.duration } ?? 0) - clock - (sample.time - previous.time)
                    if previous.key == owner.key, remaining > 0,
                       !owner.layers.contains(where: { $0.id == previous.layer.id }),
                       owner.layers.reduce(Float(1), { $0 * $1.opacity }) >= 0.98 {
                        issues.append("\(phase.name): \(owner.key): native insertion owner retired before fade completion (last opacity \(String(format: "%.3f", previous.layer.opacity)); pixel continuity unverified)")
                    }
                    fading[owner.marker] = nil
                }
                if let layer = owner.layers.first(where: { layer in
                    layer.modelOpacity == 1 && layer.opacity < 0.98 && layer.animations.contains {
                        $0.keyPath == "opacity" && $0.from == "0" && !$0.additive
                    }
                }) {
                    fading[owner.marker] = (owner.key, layer, sample.time)
                }
            }
        }
        return issues
    }

    static func failures(in report: Report) -> [String] {
        var failures = (report.rejectedRoutes ?? []) + pollingFailures(report)
        failures += report.phases.flatMap(ownerFailures)
        let expected: [String: (rows: Int, children: Int)] = [
            "children-insert": (5, 3), "children-swap": (5, 3),
            "children-remove-one": (5, 2), "children-remove-all": (5, 0),
            "parent-insert-and-focus": (6, 0), "parent-move-and-echo": (6, 0),
            "parent-delete-and-focus": (5, 0), "parent-remote-swap": (5, 0),
            "parent-insert-during-content-echo": (6, 0), "parent-remove-during-content-echo": (5, 0),
            "children-during-content-echo": (5, 3), "parent-drop-rollback": (5, 3),
            "children-rapid-retarget": (5, 4), "metadata-only": (5, 4), "scroll-remount": (30, 4),
            "parent-delete-last": (0, 0), "parent-insert-first": (1, 0),
            "parent-insert-second": (2, 0), "parent-move-pair": (2, 0), "parent-delete-selected": (1, 0)]
        let tables = Set(report.phases.flatMap { $0.samples.map(\.table) })
        if tables.count != 1 || tables.contains("none") { failures.append("Native table identity changed or was missing") }
        for phase in report.phases {
            guard let before = phase.samples.first, let after = phase.samples.last else { continue }
            if phase.samples.contains(where: { $0.selection != -1 || $0.focus.contains("TableView") }) {
                failures.append("\(phase.name): native selection or keyboard focus changed")
            }
            if phase.mutations != nil {
                failures += assessStress(phase, reduced: report.reduceMotion).issues.map { "\(phase.name): \($0)" }
                if !report.simpleDetail, !after.hasComposerFocus {
                    failures.append("\(phase.name): composer focus was not restored")
                }
                continue
            }
            let initial = Set(before.markers.keys), final = Set(after.markers.keys)
            guard let outcome = expected[phase.name] else { failures.append("Unknown phase: \(phase.name)"); continue }
            let groups = final.filter { $0.hasPrefix("group:") }.count
            if after.rows != outcome.rows || final.filter({ $0.hasPrefix("child:") }).count != outcome.children
                || (outcome.rows > 0 && groups == 0) || (phase.name != "scroll-remount" && groups != outcome.rows)
                || final.filter({ $0.hasPrefix("parent:") }).count != groups
                || final.filter({ $0.hasPrefix("footer:") }).count != groups {
                failures.append("\(phase.name): missing markers or incorrect final row/child counts")
            }
            if after.markers.values.contains(where: { $0.opacity < 0.98 || $0.height <= 0 || $0.width <= 0 }) {
                failures.append("\(phase.name): a settled row remained invisible or empty")
            }
            if phase.name.hasPrefix("children-"), !report.simpleDetail,
               (!before.hasComposerFocus || after.focus != before.focus) {
                failures.append("\(phase.name): composer focus was not preserved")
            }
            if ["children-swap", "parent-remote-swap", "parent-move-and-echo", "parent-move-pair"].contains(phase.name) {
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
            failures += opacityContinuityFailures(phase).map { "\(phase.name): \($0)" }
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

    /// Several intermediate values are necessary but not sufficient: a fade can
    /// still jump between them. Keep uncertainty separate from observed jumps.
    static func opacityContinuityFailures(_ phase: Phase) -> [String] {
        var issues: [String] = []
        let keys = Set(phase.samples.flatMap { $0.markers.keys }).filter {
            $0.hasPrefix("group:") || $0.hasPrefix("child:")
        }
        for key in keys.sorted() {
            if phase.samples.contains(where: { $0.duplicateMarkers?.contains(key) == true }) {
                issues.append("\(key): ambiguous duplicate presentation markers")
                continue
            }
            let pairs = zip(phase.samples, phase.samples.dropFirst())
            let gapped = pairs.contains { a, b in
                let x = a.markers[key]?.opacity ?? 0, y = b.markers[key]?.opacity ?? 0
                return b.time - a.time >= 0.06 &&
                    (abs(y - x) > 0.02 || (x > 0.02 && x < 0.98) || (y > 0.02 && y < 0.98))
            }
            let jumped = pairs.contains { a, b in
                guard b.time - a.time < 0.06, let x = a.markers[key]?.opacity,
                      let y = b.markers[key]?.opacity else { return false }
                return abs(y - x) > 0.6
            }
            if gapped { issues.append("\(key): fade continuity undersampled\(jumped ? " (post-stall opacity jump)" : "")") }
            else if jumped { issues.append("\(key): sampled opacity jumped by >0.6 within 60ms") }
        }
        return issues
    }

    /// Model-layer control for sizing copies that remain in the native view tree.
    /// Live workloads separately exercise the presentation-layer ancestry path.
    @MainActor static func verifyMarkerAttachment() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        host.wantsLayer = true
        let markers = (0..<2).map { _ in SidebarProbeMarker.Marker(frame: NSRect(x: 20, y: 40, width: 180, height: 40)) }
        for marker in markers {
            marker.key = "group:attachment-control"
            marker.wantsLayer = true
            host.addSubview(marker)
        }
        guard let root = host.layer, let detached = markers.last?.layer else {
            throw ExecError("Missing attachment control layers")
        }
        for marker in markers { root.addSublayer(marker.layer!) }
        let attached = sample(host, start: 0)
        guard attached.duplicateMarkers == [markers[0].key] else {
            throw ExecError("Attached duplicate markers were not detected")
        }
        detached.removeFromSuperlayer()
        let measured = sample(host, start: 0)
        guard measured.markers.count == 1, measured.duplicateMarkers?.isEmpty == true,
              measured.detachedMarkers == [markers[0].key], descendants(host).count == 3 else {
            throw ExecError("Detached native sizing copy polluted window geometry")
        }
        print("PASS attachment control: detached sizing layers excluded; attached duplicates still rejected")
    }

    /// Negative control: keep native animation keys and correct final positions,
    /// but replace every intermediate frame with an instantaneous endpoint jump.
    /// This prevents the regression gate itself from degrading to endpoint checks.
    @MainActor static func verifySnapDetection(_ report: Report) throws {
        try verifyMarkerAttachment()
        guard !report.reduceMotion, report.stress == nil, report.polling == nil else {
            throw ExecError("Detector verification needs the default motion workload")
        }
        let phases = report.phases.map { phase in
            guard let first = phase.samples.first, let last = phase.samples.last else { return phase }
            let snapped = phase.samples.dropFirst().map { frame in
                Sample(time: frame.time, markers: last.markers, animations: frame.animations,
                       rows: last.rows, selection: frame.selection, table: frame.table,
                       focus: frame.focus, duplicateMarkers: frame.duplicateMarkers,
                       composerFocused: frame.composerFocused)
            }
            return Phase(name: phase.name, samples: [first] + snapped, startedAt: phase.startedAt)
        }
        let issues = failures(in: Report(operatingSystem: report.operatingSystem, reduceMotion: false,
                                        simpleDetail: report.simpleDetail, phases: phases))
        guard issues.contains(where: { $0.contains("snapped instead of moving") }),
              issues.contains(where: { $0.contains("appeared/disappeared without fading") }) else {
            throw ExecError("Animation checks accepted instantaneous movement or visibility")
        }
        print("PASS negative controls: instantaneous reordering and appearance were rejected")
        func fixture(_ opacity: [Double], gap: Bool = false, duplicate: Bool = false) -> Phase {
            Phase(name: "continuity-control", samples: opacity.enumerated().map { index, value in
                Sample(time: Double(index) * 0.01 + (gap && index >= 3 ? 0.1 : 0),
                       markers: ["group:control": Geometry(x: 0, y: 0, width: 200, height: 40, opacity: value)],
                       animations: ["opacity"], rows: 1, selection: -1, table: "control", focus: "control",
                       duplicateMarkers: duplicate && index == 3 ? ["group:control"] : [])
            })
        }
        // Correct endpoints and at least three intermediate alphas do not excuse
        // one discontinuity. A sampling stall or duplicate marker is inconclusive.
        let smooth = (0...10).map { Double($0) / 10 }
        guard opacityContinuityFailures(fixture(smooth)).isEmpty,
              opacityContinuityFailures(fixture([0, 0.1, 0.2, 0.9, 0.95, 1])).contains(where: { $0.contains("opacity jumped") }),
              opacityContinuityFailures(fixture(smooth, gap: true)).contains(where: { $0.contains("undersampled") }),
              opacityContinuityFailures(fixture(smooth, duplicate: true)).contains(where: { $0.contains("ambiguous") }) else {
            throw ExecError("Opacity continuity detector accepted a discontinuity or rejected smooth samples")
        }
        print("PASS continuity controls: smooth accepted; jumps, sampling gaps and duplicate markers rejected")
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
                    // A post-stall presentation sample can lag, then catch up on
                    // the next tick. Gaps during a fade remain inconclusive even
                    // with enough other intermediate values; never pass them silently.
                    let fadeEnd = min(end, mutation.time + 0.35)
                    let gapped = zip(phase.samples, phase.samples.dropFirst()).contains { a, b in
                        b.time + start >= mutation.time && a.time + start < fadeEnd && b.time - a.time >= 0.06
                    }
                    if !reduced {
                        let jumped = zip(boundaryFrames, boundaryFrames.dropFirst()).contains { a, b in
                            guard b.time - a.time < 0.06, let x = a.markers[key]?.opacity,
                                  let y = b.markers[key]?.opacity else { return false }
                            return abs(y - x) > 0.6
                        }
                        if gapped { issues.append("mutation \(index) \(key): fade continuity undersampled\(jumped ? " (post-stall opacity jump)" : "")") }
                        else if jumped { issues.append("mutation \(index) \(key): sampled opacity jumped by >0.6 within 60ms") }
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
                // A metadata title may change its intrinsic height immediately;
                // the structural contract is the containing group's layout height.
                // Wrapping grows downward: compare the title's anchored TOP,
                // not its lower edge (which moves with intrinsic text height).
                let properties = key.hasPrefix("group:") ? [\Geometry.y, \Geometry.height] :
                    [key.hasPrefix("parent:") ? \Geometry.top : \Geometry.y]
                for property in properties {
                    let origin = a.markers[key]![keyPath: property], destination = b.markers[key]![keyPath: property]
                    guard abs(origin - destination) > 1 else { continue }
                    let values = frames.compactMap { $0.markers[key]?[keyPath: property] }
                    let intermediate = values.filter { $0 > min(origin, destination) + 0.1 && $0 < max(origin, destination) - 0.1 }
                    let trajectory = frames.compactMap { frame in frame.markers[key].map { (frame.time, $0[keyPath: property]) } }
                    let label = property == \Geometry.height ? "height" : "position"
                    if !reduced, distinct(intermediate) < 3 {
                        let gap = zip(trajectory, trajectory.dropFirst()).contains { a, b in b.0 - a.0 > 0.06 && abs(b.1 - a.1) > 1 }
                        issues.append("\(key): retained \(label) \(gap ? "undersampled" : "snapped")")
                    }
                    if !reduced, property == \Geometry.height,
                       zip(trajectory, trajectory.dropFirst()).contains(where: { a, b in
                           b.0 - a.0 < 0.06 && abs(b.1 - a.1) > max(2, abs(destination - origin) * 0.6)
                       }) { issues.append("\(key): height jumped by >60% within 60ms") }
                }
            }
        }
        if reduced, phase.samples.contains(where: { !$0.animations.isEmpty }) { issues.append("native animation with Reduce Motion") }
        return (issues, checked, short, unseen)
    }

    static func pollingFailures(_ report: Report) -> [String] {
        guard let polling = report.polling else { return [] }
        let events = report.pollingEvidence ?? []
        var issues: [String] = []
        let loads = events.filter { $0.kind == "sync-initial" }
        if loads.count < (polling.navigate ? 2 : 1) || !events.contains(where: { $0.kind == "sync-before" }) ||
            events.filter({ $0.kind == "sync-after" }).count < polling.cycles * 4 {
            issues.append("Polling did not exercise cold load, history backfill and repeated suffix sync")
        }
        if report.phases.count != polling.cycles { issues.append("Incomplete polling cycles") }
        if polling.append == true, events.filter({ $0.kind == "append" }).count != polling.cycles * 2 {
            issues.append("Polling did not exercise transcript appends during every structural update")
        }
        for stage in 1...(polling.cycles * 2) {
            guard let catalog = events.first(where: { $0.kind == "catalog" && $0.stage == stage }),
                  let title = events.first(where: { $0.kind == "title" && $0.stage == stage }) else {
                issues.append("Polling stage \(stage): missing catalog/title evidence"); continue
            }
            if !(0...0.25).contains(title.time - catalog.time) {
                issues.append("Polling stage \(stage): title response did not overlap the 250ms structural animation")
            }
        }
        guard let root = events.first(where: { $0.kind == "title" })?.session else { return issues }
        for phase in report.phases {
            let coverage = assessStress(phase, reduced: report.reduceMotion)
            // Immediate removal is expected with Reduce Motion: no departing
            // marker/fade window is required, only correct settled endpoints.
            if !report.reduceMotion, coverage.short > 0 || coverage.unseen > 0 {
                issues.append("\(phase.name): undersampled fade windows (short=\(coverage.short), unobserved=\(coverage.unseen))")
            }
            guard let before = phase.samples.first, let after = phase.samples.last, let peak = phase.peak else {
                issues.append("\(phase.name): missing polling endpoints"); continue
            }
            for frame in [before, peak, after] {
                for role in ["group:", "parent:", "footer:"] where frame.markers.keys.filter({ $0.hasPrefix(role) }).count != 5 {
                    issues.append("\(phase.name): missing settled \(role) markers")
                }
            }
            let key = "parent:\(root)"
            if let a = before.markers[key], let b = peak.markers[key], let c = after.markers[key] {
                if b.height - a.height < 2 || abs(c.height - a.height) > 0.5 {
                    issues.append("\(phase.name): title metadata did not grow and restore parent geometry")
                }
                if phase.samples.contains(where: { abs(($0.markers[key]?.top ?? a.top) - a.top) > 0.5 }) {
                    issues.append("\(phase.name): parent title top moved during child resizing")
                }
            } else { issues.append("\(phase.name): missing title geometry evidence") }
            if !report.simpleDetail, !polling.navigate,
               phase.samples.contains(where: { !$0.hasComposerFocus || $0.focus != before.focus }) {
                issues.append("\(phase.name): composer focus changed without navigation")
            }
        }
        return issues
    }

    static func printIssues(_ issues: [String], report: Report) {
        if let polling = report.polling {
            let events = report.pollingEvidence ?? []
            let reads = events.filter { $0.kind.hasPrefix("sync-") }
            print("Polling: \(polling.messages) messages/session, navigation=\(polling.navigate); initial=\(reads.filter { $0.kind == "sync-initial" }.count), backfill=\(reads.filter { $0.kind == "sync-before" }.count), suffix=\(reads.filter { $0.kind == "sync-after" }.count); \(reads.reduce(0) { $0 + $1.bytes }) sync response bytes")
        }
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
        let arguments = CommandLine.arguments
        let retarget = arguments.firstIndex(of: "--stress-retarget").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        guard retarget == nil || ["metadata", "title", "title-inserted", "title-retained", "resize", "screen", "reorder"].contains(retarget!) else {
            throw ExecError("Invalid --stress-retarget")
        }
        guard retarget == nil || stress.intervalMS >= 40 else { throw ExecError("Retarget needs interval >= 40ms") }
        var longTitle = false
        var reverseRoots = false
        let stableParents = (0..<stress.batch).map { _ in UUID() }
        let stableChildren = (0..<stress.batch).map { _ in UUID() }
        var tick = 0
        func snapshots(_ parents: [UUID], _ children: [UUID]) -> [AgentJSON] {
            (parents + (reverseRoots ? [roots[1], roots[0]] + Array(roots.dropFirst(2)) : roots)).enumerated().map {
                SidebarProbeTransport.snapshot($0.element,
                    title: longTitle && (retarget != "title-inserted" || parents.contains($0.element))
                        && (retarget != "title-retained" || $0.element == roots[1])
                        ? SidebarProbeTransport.longTitle : "Stress conversation \($0.offset + 1)", activity: Double(1000 + tick))
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
                let delay = retarget == nil ? stress.intervalMS / 2 : 40
                try await Task.sleep(for: .milliseconds(delay))
                if let retarget {
                    tick += 1
                    if retarget.hasPrefix("title") { longTitle.toggle() }
                    if retarget == "reorder" { reverseRoots.toggle() }
                    if retarget == "resize" {
                        guard let split = descendants(host).compactMap({ $0 as? NSSplitView }).first else {
                            throw ExecError("Missing split view for resize")
                        }
                        split.setPosition(step.isMultiple(of: 2) ? 200 : 300, ofDividerAt: 0)
                    } else if retarget == "screen" {
                        guard NSScreen.screens.count > 1, let window = host.window else {
                            throw ExecError("Cross-screen workload requires two physical screens")
                        }
                        let current = window.screen.flatMap { NSScreen.screens.firstIndex(of: $0) } ?? 0
                        let frame = NSScreen.screens[(current + 1) % NSScreen.screens.count].visibleFrame
                        window.setFrameOrigin(NSPoint(x: frame.minX + 40, y: frame.maxY - window.frame.height - 40))
                    }
                    try await install(currentParents, currentChildren)
                }
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
                try await Task.sleep(for: .milliseconds(stress.intervalMS - delay))
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

    /// Sleeps below only yield for observation/settling. Work is driven by the
    /// unchanged production 2s catalog loop and active 200ms transcript readers.
    @MainActor private static func pollingPhases(_ polling: Polling, host: NSView, library: ChatLibrary,
        transport: SidebarProbeTransport, roots: [UUID], children: [UUID]) async throws -> [Phase] {
        func observe(_ label: String, until condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 10
            while !condition() {
                guard library.error == nil, library.connectionError == nil else {
                    throw ExecError("Polling observation failed: \(library.error ?? library.connectionError!)")
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw ExecError("Timed out observing \(label)") }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        library.startSynchronization()
        var phases: [Phase] = []
        for cycle in 0..<polling.cycles {
            var mutations: [Mutation] = []
            var peak: Sample?
            var phase = try await measure("polling-\(cycle + 1)", host: host) {
                await transport.armPollingCycle()
                for inserting in [true, false] {
                    try await observe(inserting ? "catalog insertion" : "catalog removal") {
                        library.childSessions(of: roots[0]).count == (inserting ? children.count : 0)
                    }
                    // First observation of applied library state, NOT synthetic server time.
                    let keys = children.map { "child:\($0)" }
                    mutations.append(Mutation(time: ProcessInfo.processInfo.systemUptime,
                        inserted: inserting ? keys : [], removed: inserting ? [] : keys,
                        rows: roots.count, selection: library.sidebarSelectionID))
                    if polling.navigate {
                        let target = inserting ? roots[1] : roots[0]
                        library.openSession(target)
                        await library.waitForNavigation()
                        guard library.currentSessionID == target, library.current.messages.count >= polling.messages else {
                            throw ExecError("Polling navigation did not load the complete synthetic transcript")
                        }
                    }
                    try await observe("reader title update") {
                        library.sessionList.first { $0.id == roots[0] }?.title ==
                            (inserting ? SidebarProbeTransport.longTitle : "Conversation 1")
                    }
                    try await Task.sleep(for: .milliseconds(350)) // Settled endpoint, not workload.
                    if inserting { peak = sample(host, start: 0) }
                }
            }
            phase.mutations = mutations
            if let peak, let start = phase.startedAt {
                phase.peak = Sample(time: peak.time - start, markers: peak.markers, animations: peak.animations,
                    rows: peak.rows, selection: peak.selection, table: peak.table, focus: peak.focus,
                    duplicateMarkers: peak.duplicateMarkers)
            }
            phases.append(phase)
        }
        return phases
    }

    /// Actual new-conversation APIs plus the normal reader/catalog delivery paths.
    /// The 40ms title is synthetic backend timing, never a production delay.
    @MainActor private static func freshTitlePhases(host: NSView, library: ChatLibrary,
        transport: SidebarProbeTransport, workspace: URL) async throws -> [Phase] {
        library.startSynchronization()
        var phases: [Phase] = []
        for cycle in 1...3 {
            var mutations: [Mutation] = []
            var peak: Sample?
            var phase = try await measure("stress-fresh-title-\(cycle)", host: host) {
                library.newConversation()
                guard let pending = library.pendingNewConversation else { throw ExecError("Missing pending creation") }
                pending.consumeInitialWorkspaceSelection()
                library.selectWorkspace(workspace, in: pending)
                let creationDeadline = ProcessInfo.processInfo.systemUptime + 3
                while pending.currentSessionID == nil || !library.sidebarSessions.contains(where: { $0.id == pending.currentSessionID }) {
                    guard ProcessInfo.processInfo.systemUptime < creationDeadline else { throw ExecError("Fresh creation failed") }
                    try await Task.sleep(for: .milliseconds(1))
                }
                let id = pending.currentSessionID!
                let key = "group:\(id)"
                mutations.append(Mutation(time: ProcessInfo.processInfo.systemUptime, inserted: [key], removed: [],
                    rows: library.sidebarSessions.count, selection: id))
                try await Task.sleep(for: .milliseconds(40))
                try await transport.autoTitle(id)
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while library.sessionList.first(where: { $0.id == id })?.title != SidebarProbeTransport.longTitle {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw ExecError("Fresh reader did not deliver title") }
                    try await Task.sleep(for: .milliseconds(10))
                }
                mutations.append(Mutation(time: ProcessInfo.processInfo.systemUptime, inserted: [], removed: [],
                    rows: library.sidebarSessions.count, selection: id))
                await library.waitForNavigation()
                guard library.current === pending else { throw ExecError("Fresh navigation did not settle") }
                try await Task.sleep(for: .milliseconds(500))
                peak = sample(host, start: 0)
                library.deleteSession(id)
                await library.waitForNavigation()
                mutations.append(Mutation(time: ProcessInfo.processInfo.systemUptime, inserted: [], removed: [key],
                    rows: library.sidebarSessions.count, selection: library.sidebarSelectionID))
                try await Task.sleep(for: .milliseconds(500))
            }
            phase.mutations = mutations
            if let peak, let start = phase.startedAt {
                phase.peak = Sample(time: peak.time - start, markers: peak.markers, animations: peak.animations,
                    rows: peak.rows, selection: peak.selection, table: peak.table, focus: peak.focus,
                    duplicateMarkers: peak.duplicateMarkers)
            }
            phases.append(phase)
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
            if arguments.contains("--verify-detectors") { try verifySnapDetection(report) }
            return
        }
        let stress = try Stress(arguments)
        let polling = try Polling(arguments)
        guard stress.cycles == 0 || polling.cycles == 0 else { throw ExecError("Choose stress OR polling workload") }
        let suite = "exec-sidebar-probe-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: workspace) }
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
        if polling.cycles > 0 {
            try await transport.configurePolling(messages: polling.messages, roots: parentIDs, children: children,
                                                 append: polling.append == true)
            try await library.current.loadSession(parentIDs[0])
            guard library.current.messages.count == polling.messages else { throw ExecError("Incomplete polling history backfill") }
        } else {
            try library.current.apply(parents[0].decoded(AgentSnapshot.self))
        }
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
        if let index = arguments.firstIndex(of: "--screen") {
            guard arguments.indices.contains(index + 1), let screen = Int(arguments[index + 1]),
                  NSScreen.screens.indices.contains(screen) else { throw ExecError("Invalid --screen index") }
            let frame = NSScreen.screens[screen].visibleFrame
            window.setFrameOrigin(NSPoint(x: frame.minX + 40, y: frame.maxY - window.frame.height - 40))
        }
        if arguments.contains("--in-place") {
            window.orderFront(nil) // Never activate or steal another probe's key window.
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        print("Screens: \(NSScreen.screens.enumerated().map { "\($0.offset): \($0.element.frame), scale=\($0.element.backingScaleFactor)" })")
        print("Probe screen=\(window.screen.flatMap { NSScreen.screens.firstIndex(of: $0) } ?? -1), scale=\(window.backingScaleFactor)")
        defer { window.orderOut(nil); window.contentView = nil }
        var hiddenReveal: Sample?
        try await Task.sleep(for: .milliseconds(800))
        if arguments.contains("--hidden-updates") {
            if !arguments.contains("--reveal-sidebar") { try await toggleSidebar(host, visible: false) }
            // Change parents, children and ordering while the native sidebar is
            // collapsed. It must reveal the current catalog, not a stale snapshot.
            await transport.install(Array(parents.prefix(2).reversed()) + children)
            try await library.refreshSharedState()
            try await Task.sleep(for: .milliseconds(400))
            try await toggleSidebar(host, visible: true)
            let revealed = sample(host, start: ProcessInfo.processInfo.systemUptime)
            hiddenReveal = revealed
            let expected = Set(parentIDs.prefix(2).flatMap { id in ["group:\(id)", "parent:\(id)", "footer:\(id)"] }
                + childIDs.map { "child:\($0)" })
            guard Set(revealed.markers.keys) == expected, revealed.rows == 2,
                  revealed.markers.values.allSatisfy({ $0.opacity >= 0.98 && $0.width > 0 && $0.height > 0 }) else {
                throw ExecError("Hidden catalog changes did not reconcile on reveal")
            }
            await transport.install(parents)
            try await library.refreshSharedState()
            try await Task.sleep(for: .milliseconds(400))
        } else if arguments.contains("--reveal-sidebar") { try await toggleSidebar(host, visible: true) }
        if arguments.contains("--narrow"), let split = descendants(host).compactMap({ $0 as? NSSplitView }).first {
            split.setPosition(200, ofDividerAt: 0)
            try await Task.sleep(for: .milliseconds(300))
        }
        var phases: [Phase] = []
        if arguments.contains("--fresh-title") {
            phases = try await freshTitlePhases(host: host, library: library, transport: transport, workspace: workspace)

        } else if polling.cycles > 0 {
            phases = try await pollingPhases(polling, host: host, library: library, transport: transport,
                                            roots: parentIDs, children: childIDs)
        } else if stress.cycles > 0 {
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
            let previous = library.current
            library.newConversation()
            guard let pending = library.pendingNewConversation, pending.needsInitialWorkspaceSelection,
                  library.current === previous else { throw ExecError("Missing pending workspace creation flow") }
            // Supply the empty isolated workspace in place of the native picker.
            pending.consumeInitialWorkspaceSelection()
            library.selectWorkspace(workspace, in: pending)
            await library.waitForNavigation()
            guard library.current === pending, pending.currentSessionID != nil, library.pendingNewConversation == nil,
                  library.sidebarSessions.count == 6 else { throw ExecError("Synthetic creation did not finish: \(library.error ?? "no error")") }
        })
        phases.append(try await measure("parent-move-and-echo", host: host) {
            let offsets = IndexSet(integer: 1)
            var expected = library.sidebarSessions.map(\.id)
            let destination = expected.count
            expected.move(fromOffsets: offsets, toOffset: destination)
            try SidebarProbeMove.perform(from: offsets, to: destination, library: library)
            guard library.sidebarSessions.map(\.id) == expected else { throw ExecError("Drop order wasn't applied synchronously") }
            await library.waitForNavigation()
            guard library.sidebarSessions.map(\.id) == expected else { throw ExecError("Persistence echo changed the drop order") }
        })
        phases.append(try await measure("parent-delete-and-focus", host: host) {
            if let id = library.currentSessionID { library.deleteSession(id) }
        })
        phases.append(try await measure("parent-remote-swap", host: host) {
            await transport.reorder(Array(library.sessionList.map(\.id).reversed()))
            try await library.refreshSharedState()
        })
        if arguments.contains("--parent-echo") {
            let id = UUID()
            let inserted = SidebarProbeTransport.snapshot(id, title: "Echo conversation")
            let changed = parentIDs.enumerated().map {
                SidebarProbeTransport.snapshot($0.element, title: "Conversation \($0.offset + 1)", activity: 2000)
            }
            phases.append(try await measure("parent-insert-during-content-echo", host: host) {
                await transport.install([inserted] + parents)
                try await library.refreshSharedState()
                try await Task.sleep(for: .milliseconds(40))
                await transport.install([SidebarProbeTransport.snapshot(id, title: "Echo conversation", activity: 2000)] + changed)
                try await library.refreshSharedState()
            })
            phases.append(try await measure("parent-remove-during-content-echo", host: host) {
                await transport.install(parents)
                try await library.refreshSharedState()
                try await Task.sleep(for: .milliseconds(40))
                await transport.install(changed)
                try await library.refreshSharedState()
            })
        }
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
        if arguments.contains("--empty-lifecycle") {
            await transport.install(parents)
            try await library.refreshSharedState()
            for id in library.sidebarSessions.dropFirst().map(\.id) {
                library.deleteSession(id)
                await library.waitForNavigation()
                guard !library.sidebarSessions.contains(where: { $0.id == id }) else {
                    throw ExecError("Empty lifecycle setup failed to delete a session")
                }
            }
            try await Task.sleep(for: .milliseconds(600))
            phases.append(try await measure("parent-delete-last", host: host) {
                library.deleteSession(library.sidebarSessions[0].id)
                await library.waitForNavigation()
            })
            for name in ["parent-insert-first", "parent-insert-second"] {
                phases.append(try await measure(name, host: host) {
                    windows.newConversation()
                    guard let pending = library.pendingNewConversation else { throw ExecError("Missing pending creation") }
                    pending.consumeInitialWorkspaceSelection()
                    library.selectWorkspace(workspace, in: pending)
                    await library.waitForNavigation()
                    guard library.current === pending, pending.currentSessionID != nil else {
                        throw ExecError("Empty lifecycle creation failed")
                    }
                })
            }
            phases.append(try await measure("parent-move-pair", host: host) {
                library.moveSidebarSessions(from: IndexSet(integer: 0), to: 2)
            })
            phases.append(try await measure("parent-delete-selected", host: host) {
                library.deleteSession(library.currentSessionID!)
                await library.waitForNavigation()
            })
        }
        }
        library.closePresentations()
        let report = Report(operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                            reduceMotion: reduceMotion, simpleDetail: simple, phases: phases,
                            stress: stress.cycles > 0 ? stress : nil,
                            polling: polling.cycles > 0 ? polling : nil,
                            pollingEvidence: await transport.evidence,
                            rejectedRoutes: await transport.rejected,
                            probeBuild: try? String(contentsOfFile: CommandLine.arguments[0] + ".sources", encoding: .utf8),
                            lifecycleOptions: arguments.filter {
                                ["--reveal-sidebar", "--hidden-updates", "--cycle-sidebar", "--empty-lifecycle", "--parent-echo"].contains($0)
                            }, hiddenReveal: hiddenReveal, arguments: Array(arguments.dropFirst()))
        let args = CommandLine.arguments
        let output = args.firstIndex(of: "--output").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            ?? ".build/sidebar-animation-report.json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = stress.cycles > 0 || polling.cycles > 0 ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: output))
        print("Report: \(output). Samples inspect owned view/layer geometry, not screenshots. Native drag gestures are not simulated.")
        let issues = failures(in: report)
        print("\(issues.isEmpty ? "PASS" : "FAIL"): \(phases.count) phases, \(issues.count) check failures")
        printIssues(issues, report: report)
        if args.contains("--check"), !issues.isEmpty { throw ExecError("Sidebar animation checks failed") }
        if args.contains("--verify-detectors") { try verifySnapDetection(report) }
    }
}
