import AppKit
import SwiftUI

// Visual experiments only. This multi-animation window is not a CPU benchmark.
private struct Variation: Identifiable {
    let id: Int
    let name: String
    let detail: String
    let pattern: Int
    var speed = 1.495
    var columns = 5
    var rows = 3
    var spacing = 6.0
    var diameter = 2.5
    var exponent = 2.0

    static let all: [Variation] = [
        .init(id: 1, name: "Current", detail: "5×3 · existing neural pulses", pattern: 0),
        .init(id: 2, name: "Slow breathing", detail: "Gentler fades · 30% slower", pattern: 0, speed: 1.05, exponent: 1.3),
        .init(id: 3, name: "Quick sparks", detail: "Sharper pulses · 30% faster", pattern: 0, speed: 1.95, exponent: 3.5),
        .init(id: 4, name: "Ripples", detail: "Waves expanding from the center", pattern: 1, speed: 1.3),
        .init(id: 5, name: "Independent neurons", detail: "Asynchronous pulses · no travelling wave", pattern: 2, speed: 1.5),
        .init(id: 6, name: "Signal sweep", detail: "A soft cluster scans back and forth", pattern: 3, speed: 1.4),
        .init(id: 7, name: "Cross currents", detail: "Two diagonal waves intersect", pattern: 4, speed: 1.3),
        .init(id: 8, name: "Compact", detail: "5×3 · smaller, closely spaced dots", pattern: 0, columns: 5, spacing: 4.5, diameter: 2),
        .init(id: 9, name: "Bold nodes", detail: "4×3 · larger dots, wider spacing", pattern: 2, speed: 1.4, columns: 4, spacing: 7, diameter: 3.5, exponent: 1.6),
        .init(id: 10, name: "Dense network", detail: "6×4 · small dots, fine texture", pattern: 2, speed: 1.65, columns: 6, rows: 4, spacing: 4.5, diameter: 2)
    ]

    func brightness(column: Int, row: Int, time: Double) -> Double {
        let t = time * speed
        let x = Double(column)
        let y = Double(row)
        let index = Double(row * 7 + column)
        let phase = index * 2.399
        let pulse = sin(t * (1.7 + index.truncatingRemainder(dividingBy: 5) * 0.19) + phase)
        let value: Double
        switch pattern {
        case 1:
            let distance = hypot(x - Double(columns - 1) / 2, y - Double(rows - 1) / 2)
            value = sin(t * 2.4 - distance * 1.6) * 0.8 + pulse * 0.2
        case 2:
            value = pulse * 0.75 + sin(t * 0.7 + phase * 1.3) * 0.25
        case 3:
            let head = (sin(t * 1.6) + 1) / 2 * Double(columns - 1)
            value = exp(-pow(x - head, 2) / 1.3) * (0.65 + pulse * 0.35)
        case 4:
            value = (sin(t * 2.1 - x * 0.9 - y * 1.1) + sin(t * 1.6 + x * 0.8 - y)) / 2
        default:
            value = (sin(t * 2.3 - x * 0.85 + y * 1.2) + pulse) / 2
        }
        return min(1, pow(max(0, value + 0.1), exponent) * 2.5)
    }
}

private struct Dots: View {
    let variation: Variation
    let time: Double
    var scale = 1.0

    var body: some View {
        Canvas { context, size in
            let width = Double(variation.columns - 1) * variation.spacing * scale
            let height = Double(variation.rows - 1) * variation.spacing * scale
            let diameter = variation.diameter * scale
            for row in 0..<variation.rows {
                for column in 0..<variation.columns {
                    let x = (size.width - width) / 2 + Double(column) * variation.spacing * scale
                    // AppKit's production indicator draws from the bottom up.
                    let y = (size.height + height) / 2 - Double(row) * variation.spacing * scale
                    let dot = Path(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2,
                                                     width: diameter, height: diameter))
                    context.fill(dot, with: .color(Color(nsColor: .quaternaryLabelColor).opacity(0.25)))
                    context.fill(dot, with: .color(Color(nsColor: .controlAccentColor).opacity(
                        variation.brightness(column: column, row: row, time: time))))
                }
            }
        }
        .frame(width: 120, height: 54)
        .accessibilityLabel(variation.name)
    }
}

private struct Preview: View {
    @State private var start = Date()
    @State private var paused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thinking indicator variations").font(.title2.bold())
                    Text("Choose a number. Left: actual size · Right: 3× detail").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Pause", isOn: $paused).toggleStyle(.checkbox)
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || reduceMotion)) { timeline in
                let time = reduceMotion ? 0.8 : timeline.date.timeIntervalSince(start)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Variation.all) { variation in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(variation.id). \(variation.name)").font(.headline)
                            Text(variation.detail).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Dots(variation: variation, time: time)
                                Spacer(minLength: 8)
                                Dots(variation: variation, time: time, scale: 3)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            Text("Preview only—no app setting changes. Ten simultaneous animations are not a performance benchmark.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 760)
    }
}

@MainActor private final class PreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main private struct IndicatorPreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = PreviewDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        let host = NSHostingView(rootView: Preview())
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Exec — Indicator Variations"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(delegate) { app.run() }
    }
}
