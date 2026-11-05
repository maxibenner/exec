import SwiftUI

/// The eight-cell, fourteen-frame bounce from pi-config's personal footer.
enum WorkingFrames {
    static func frame(_ step: Int) -> [Character] {
        let step = step % 14
        let head = step < 8 ? step : 14 - step
        let direction = step < 8 ? 1 : -1
        let trail: [Character] = ["█", "▓", "▒", "░"]
        return (0..<8).map { index in
            let distance = (head - index) * direction
            return trail.indices.contains(distance) ? trail[distance] : "·"
        }
    }
}

struct WorkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { context in
            let step = reduceMotion ? 0 : max(0, Int(context.date.timeIntervalSince(started) / 0.08))
            HStack(spacing: 0) {
                ForEach(Array(WorkingFrames.frame(step).enumerated()), id: \.offset) { _, character in
                    Text(String(character)).foregroundStyle(color(character))
                }
            }
            .font(.system(.caption, design: .monospaced)).fixedSize()
        }
        .accessibilityHidden(true)
    }

    private func color(_ character: Character) -> Color {
        switch character {
        case "█", "▓": .accentColor
        case "▒": .secondary
        default: .secondary.opacity(0.45)
        }
    }
}
