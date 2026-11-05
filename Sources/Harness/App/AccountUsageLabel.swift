import SwiftUI

struct AccountUsageLabel: View {
    let usage: AccountUsage

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let windows = usage.windows.filter { $0.resetsAt > context.date }
            if !windows.isEmpty {
                Text(windows.map { "\(name($0.durationSeconds)) \($0.remainingPercent)% left" }.joined(separator: " · "))
                    .monospacedDigit().fixedSize()
                    .help(windows.map { "\(name($0.durationSeconds)) limit resets \($0.resetsAt.formatted(date: .abbreviated, time: .shortened))" }.joined(separator: "\n"))
                    .accessibilityLabel("Remaining usage: " + windows.map { "\(name($0.durationSeconds)), \($0.remainingPercent) percent" }.joined(separator: ", "))
            }
        }
    }

    private func name(_ seconds: Int) -> String {
        if seconds == 604_800 { return "Weekly" }
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)d" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)h" }
        return "\(max(1, seconds / 60))m"
    }
}
