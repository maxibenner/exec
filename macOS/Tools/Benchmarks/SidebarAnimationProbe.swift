import AppKit
import SwiftUI

// Standalone synthetic experiment; no account, backend, or screen capture.
// swiftc -swift-version 6 -parse-as-library Sources/Exec/Features/Sessions/SidebarTableView.swift Tools/Benchmarks/SidebarAnimationProbe.swift -o .build/sidebar-animation-probe
// .build/sidebar-animation-probe native | snapshot | direct [disable-detail] [reduce-motion]
@MainActor @Observable private final class Rows {
    var ids = Array(0..<6)
    var busy = false
    var activations = 0
}

private struct ProbeList: View {
    let model: Rows
    let snapshot: Bool
    @State private var displayed = Array(0..<6)

    var body: some View {
        let ids = snapshot ? displayed : model.ids
        List {
            ForEach(ids, id: \.self) { id in
                Text("Conversation \(id)")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .listRowBackground(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                    .moveDisabled(model.busy)
            }
            .onMove { source, target in model.ids.move(fromOffsets: source, toOffset: target) }
        }
        .listStyle(.sidebar)
        .padding(.horizontal, 10)
        .focusable(false)
        .disabled(snapshot && model.busy)
        .animation(snapshot ? nil : .default, value: model.ids)
        .onChange(of: model.ids) { _, ids in
            if snapshot { withAnimation { displayed = ids } }
        }
    }
}

private struct ProbeRow: View {
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).lineLimit(2)
            Text("⌘1    Workspace").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
        .focusable(false)
    }
}

private struct NativeProbe: NSViewRepresentable {
    let ids: [Int]
    let model: Rows
    static func identifier(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView.wantsLayer = true
        scroll.contentView.layer?.cornerRadius = 6
        scroll.contentView.layer?.masksToBounds = true
        let table = SidebarTableView(frame: .zero)
        table.makeCell = { id, reusable in
            let content = ProbeRow(title: "Conversation \(Int(id.uuidString.suffix(12)) ?? 0)")
            if let host = reusable as? SidebarRowHostingView<ProbeRow> {
                host.rootView = content
                return host
            }
            let host = SidebarRowHostingView(rootView: content)
            host.sizingOptions = [.intrinsicContentSize]
            return host
        }
        table.activate = { _ in model.activations += 1 }
        table.canMove = { !model.busy }
        table.move = { [weak table] id, next in
            guard let source = model.ids.firstIndex(where: { Self.identifier($0) == id }) else { return false }
            let target = next.flatMap { next in model.ids.firstIndex { Self.identifier($0) == next } } ?? model.ids.count
            model.ids.move(fromOffsets: IndexSet(integer: source), toOffset: target)
            table?.update(ids: model.ids.map(Self.identifier), animated: !CommandLine.arguments.contains("reduce-motion"))
            return true
        }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? SidebarTableView)?.update(ids: ids.map(Self.identifier),
            animated: !CommandLine.arguments.contains("reduce-motion"))
    }
}

private struct ProbeWindow: View {
    let model: Rows
    let snapshot: Bool
    @FocusState private var focused: Bool
    var body: some View {
        NavigationSplitView {
            Group {
                if CommandLine.arguments.contains("native") {
                    NativeProbe(ids: model.ids, model: model)
                } else {
                    ProbeList(model: model, snapshot: snapshot)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            TextField("Composer", text: .constant(""))
                .focused($focused)
                .id(model.ids.first)
                .transaction(value: model.ids.first) { transaction in
                    transaction.animation = nil
                    if CommandLine.arguments.contains("disable-detail") {
                        transaction.disablesAnimations = true
                    }
                }
                .task(id: model.busy) {
                    guard !model.busy else { return }
                    focused = false
                    await Task.yield()
                    focused = true
                }
        }
    }
}

@main private struct SidebarAnimationProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let model = Rows()
        let snapshot = CommandLine.arguments.contains("snapshot")
        let mode = CommandLine.arguments.contains("native") ? "native" : (snapshot ? "snapshot" : "direct")
        let host = NSHostingView(rootView: ProbeWindow(model: model, snapshot: snapshot))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.title = "Sidebar animation probe — \(mode)"
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
            var tableIDs = Set<ObjectIdentifier>()
            for cycle in 0..<5 {
                for operation in ["insert", "move", "delete", "drop"] {
                    model.busy = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(50))
                        model.busy = false
                    }
                    switch operation {
                    case "insert": model.ids.insert(100 + cycle, at: 0)
                    case "delete": model.ids.removeAll { $0 == 100 + cycle }
                    case "drop" where mode == "native":
                        model.busy = false
                        if let table = descendants(host).compactMap({ $0 as? SidebarTableView }).first,
                           let id = table.itemIDs.first {
                            _ = table.acceptMove(id, before: nil)
                        }
                        model.busy = true
                    default: model.ids.move(fromOffsets: IndexSet(integer: 0), toOffset: model.ids.count)
                    }
                    var samplesWithAnimation = 0
                    var keys = Set<String>()
                    for sample in 0..<35 {
                        try? await Task.sleep(for: .milliseconds(10))
                        guard let table = descendants(host).first(where: { $0 is NSTableView }) else { continue }
                        if sample == 5, let table = table as? SidebarTableView {
                            // Persistence echoes/content refreshes must not reset a running animation.
                            table.update(ids: table.itemIDs, animated: !CommandLine.arguments.contains("reduce-motion"))
                        }
                        tableIDs.insert(ObjectIdentifier(table))
                        let active = descendants(table).flatMap { $0.layer?.animationKeys() ?? [] }
                        keys.formUnion(active)
                        if !active.isEmpty { samplesWithAnimation += 1 }
                    }
                    print("\(mode) \(cycle) \(operation): animated samples=\(samplesWithAnimation), keys=\(keys.sorted()), tables=\(tableIDs.count)")
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            if app.isActive, window.isKeyWindow,
               let table = descendants(host).compactMap({ $0 as? SidebarTableView }).first {
                let rect = table.rect(ofRow: 1)
                let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                for _ in 0..<2 {
                    let time = ProcessInfo.processInfo.systemUptime
                    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                        timestamp: time + 0.01, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 0)!
                    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                        timestamp: time, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1)!
                    app.postEvent(up, atStart: false)
                    window.sendEvent(down)
                }
                print("native repeated-click activations=\(model.activations), focusable=\(table.acceptsFirstResponder), selectionHighlight=\(table.selectionHighlightStyle.rawValue)")
            } else if mode == "native" {
                print("Click probe skipped: window is not active/key.")
            }
            window.close()
            app.stop(nil)
            app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        app.run()
    }
}
