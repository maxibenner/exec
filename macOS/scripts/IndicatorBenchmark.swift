import AppKit
import Darwin
import SwiftUI

@MainActor private final class BenchmarkState: ObservableObject {
    @Published var visible = false
    @Published var frozen = false
}

private struct BenchmarkView: View {
    @ObservedObject var state: BenchmarkState

    var body: some View {
        HStack(spacing: 8) {
            if state.visible {
                Button(action: {}) {
                    if state.frozen { FrozenIndicator() } else { WorkingIndicator() }
                }
                .buttonStyle(.plain)
                Text("esc").font(.system(.caption, design: .monospaced))
            }
            Spacer()
        }
        .frame(width: 260, height: 20)
        .padding(24)
    }
}

/// Freeze the production NSView without mutating macOS accessibility preferences.
private struct FrozenIndicator: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkingIndicator.NeuralActivityView {
        let view = WorkingIndicator.NeuralActivityView()
        view.reduceMotion = true
        return view
    }
    func updateNSView(_ view: WorkingIndicator.NeuralActivityView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WorkingIndicator.NeuralActivityView,
                     context: Context) -> CGSize? { nsView.intrinsicContentSize }
    static func dismantleNSView(_ view: WorkingIndicator.NeuralActivityView, coordinator: ()) { view.stop() }
}

/// Standalone harness: only the production indicator and a small SwiftUI host are loaded.
@main private struct IndicatorBenchmark {
    @MainActor static func main() {
        guard WorkingIndicatorProbe.enabled else {
            print("Run with EXEC_PROFILE_INDICATOR=1")
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let state = BenchmarkState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 308, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Exec indicator benchmark"
        window.level = .floating // Keep samples visible while other apps are active.
        window.contentView = NSHostingView(rootView: BenchmarkView(state: state))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            print("10 seconds per phase after 2-second settling; CPU 100% = one core.")
            print("Keep the benchmark window visible. No model calls or credential access.")
            for (name, visible, frozen) in [
                ("hidden", false, false), ("animated", true, false),
                ("frozen", true, true), ("animated again", true, false)
            ] {
                state.visible = visible
                state.frozen = frozen
                try? await Task.sleep(for: .seconds(2))
                let cpuStart = cpuSeconds()
                let start = ProcessInfo.processInfo.systemUptime
                let starts = WorkingIndicatorProbe.animationStarts
                let before = presentationOpacities(in: window.contentView)
                try? await Task.sleep(for: .seconds(10))
                let cpu = cpuSeconds() - cpuStart
                let duration = ProcessInfo.processInfo.systemUptime - start
                print(String(format: "%@: CPU %.2f%%, active layer animations %d, new animations during sample %d, visible %@",
                             name, cpu / duration * 100, WorkingIndicatorProbe.activeAnimations,
                             WorkingIndicatorProbe.animationStarts - starts,
                             window.occlusionState.contains(.visible) ? "yes" : "NO"))
                if WorkingIndicatorProbe.activeAnimations > 0 {
                    let after = presentationOpacities(in: window.contentView)
                    let moving = before.count == 15 && after.count == 15
                        && zip(before, after).contains { abs($0 - $1) > 0.01 }
                    print("Presentation-layer opacity changed: \(moving ? "yes" : "NO — sample not verified")")
                }
            }
            app.terminate(nil)
        }
        app.run()
    }

    @MainActor private static func presentationOpacities(in view: NSView?) -> [Float] {
        guard let view else { return [] }
        if view is WorkingIndicator.NeuralActivityView {
            return (view.layer?.sublayers ?? []).compactMap {
                $0.animation(forKey: "neuralPulse") == nil ? nil : $0.presentation()?.opacity
            }
        }
        return view.subviews.flatMap { presentationOpacities(in: $0) }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            fatalError("Cannot measure process CPU time")
        }
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }
}
