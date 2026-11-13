import AppKit
import SwiftUI
import Observation
import Darwin

@MainActor @Observable private final class Fixture {
    var messages: [Message]
    var revision = 0
    var follow = true
    let state = TranscriptState()

    init(count: Int) {
        messages = (0..<count).map { index in
            if index.isMultiple(of: 2) {
                return Message(role: .user, text: "Question \(index): Explain the layout and cancellation behavior for this example.")
            }
            let paragraph = "A native transcript should preserve **conversation integrity** while content changes. Keep cancellation explicit, maintain a stable reading position, and avoid unnecessary layout work."
            let text = "## Response \(index)\n\n" + Array(repeating: paragraph, count: 2 + index % 5).joined(separator: "\n\n")
                + "\n\n```swift\nfunc example() async throws {\n    try Task.checkCancellation()\n    let values = (0..<20).map { $0 * 2 }\n    print(values)\n}\n```\n\n- Preserve the current anchor\n- Reuse existing content\n- Measure before optimizing"
            return Message(role: .assistant, text: text)
        }
    }
}

@MainActor private struct LazyTranscript: View {
    let fixture: Fixture
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(fixture.messages) { message in
                            MessageView(message: message, state: fixture.state)
                                .equatable()
                                .frame(width: max(1, min(820, geometry.size.width - 40)), alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, message.id == fixture.messages.last?.id ? 172 : 0)
                                .id(message.id)
                        }
                    }
                    .padding(.top, 20)
                    .frame(maxWidth: .infinity)
                }
                .onAppear {
                    if let last = fixture.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: geometry.size.width) { _, _ in
                    if fixture.follow, let last = fixture.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: fixture.revision) { _, _ in
                    if fixture.follow, let last = fixture.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

private struct Snapshot {
    let time: Double
    let cpu: Double
    let peakBytes: Int64
    init() {
        time = ProcessInfo.processInfo.systemUptime
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        peakBytes = Int64(usage.ru_maxrss)
    }
}

@main @MainActor private enum TranscriptBenchmark {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { await run(); app.terminate(nil) }
        app.run()
    }

    static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    static func position(_ scroll: NSScrollView, fraction: Double) {
        let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum * fraction))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func measure(_ name: String, operation: () async -> Void) async {
        let start = Snapshot()
        await operation()
        let end = Snapshot()
        print(String(format: "phase=%@ wall_s=%.3f cpu_s=%.3f cpu_pct=%.1f peak_rss_mb=%.1f",
                     name, end.time - start.time, end.cpu - start.cpu,
                     100 * (end.cpu - start.cpu) / max(0.001, end.time - start.time),
                     Double(end.peakBytes) / 1_048_576))
        fflush(nil)
    }

    static func run() async {
        let args = CommandLine.arguments
        guard args.count == 4, ["virtual", "lazy"].contains(args[1]), let count = Int(args[2]), count > 1 else {
            print("Usage: transcript-benchmark virtual|lazy MESSAGE_COUNT TRIAL")
            return
        }
        let mode = args[1]
        print("BEGIN mode=\(mode) messages=\(count) trial=\(args[3]) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        let fixture = Fixture(count: count)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Transcript benchmark — \(mode) — synthetic data"
        window.level = .floating
        await measure("mount_bottom") {
            if mode == "virtual" {
                window.contentView = NSHostingView(rootView: ObservedVirtual(fixture: fixture))
            } else {
                window.contentView = NSHostingView(rootView: LazyTranscript(fixture: fixture))
            }
            window.makeKeyAndOrderFront(nil)
            await pause(1)
        }
        guard let content = window.contentView, let scroll = scrollView(in: content) else {
            print("ERROR: transcript scroll view not found")
            return
        }
        print("window_visible=\(window.isVisible) scroll_class=\(type(of: scroll)) viewport=\(scroll.contentSize)")
        fixture.follow = false
        fixture.state.followsLatest = false
        await measure("scroll_nearby") {
            for step in 0..<120 {
                let delta: CGFloat = step < 60 ? -60 : 60
                let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentSize.height)
                let y = min(maximum, max(0, scroll.contentView.bounds.minY + delta))
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                await pause(1.0 / 60)
            }
            await pause(0.3)
        }
        await measure("traverse_history") {
            // Normalized sweeps exercise distant rows, not a hardware gesture/FPS test.
            for step in 0..<240 {
                let progress = Double(step % 120) / 119
                position(scroll, fraction: step < 120 ? 1 - progress : progress)
                await pause(1.0 / 60)
            }
            await pause(0.3)
        }
        fixture.follow = true
        fixture.state.followsLatest = true
        await measure("resize_bottom") {
            for step in 0..<60 {
                let width = 1000 - 300 * sin(Double(step) / 59 * .pi)
                window.setContentSize(NSSize(width: width, height: 760))
                await pause(1.0 / 60)
            }
            await pause(0.3)
        }
        position(scroll, fraction: 1)
        fixture.follow = true
        fixture.state.followsLatest = true
        await pause(0.5)
        await measure("stream_bottom") {
            fixture.messages[fixture.messages.count - 1].status = .streaming
            for _ in 0..<80 {
                fixture.messages[fixture.messages.count - 1].text += " Additional streamed text with **formatting**."
                fixture.revision += 1
                await pause(0.03)
            }
            await pause(0.3)
        }
        let bottomGap = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.maxY)
        fixture.follow = false
        fixture.state.followsLatest = false
        position(scroll, fraction: 0.4)
        await pause(0.5)
        let readingY = scroll.contentView.bounds.minY
        await measure("stream_scrolled_up") {
            for _ in 0..<40 {
                fixture.messages[fixture.messages.count - 1].text += " Offscreen streaming update."
                fixture.revision += 1
                await pause(0.03)
            }
            await pause(0.3)
        }
        print(String(format: "checks bottom_gap_px=%.1f reading_offset_drift_px=%.1f", bottomGap, scroll.contentView.bounds.minY - readingY))
        await measure("idle") { await pause(1) }
        print("END mode=\(mode) messages=\(count) trial=\(args[3])")
        window.close()
    }
}

@MainActor private struct ObservedVirtual: View {
    let fixture: Fixture
    var body: some View {
        TranscriptView(messages: fixture.messages, state: fixture.state, bottomInset: 140)
    }
}
