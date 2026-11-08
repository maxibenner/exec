import SwiftUI

struct AccountUsageLabel: View {
    let usage: AccountUsage?
    var fetchedAt: Date? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let current = usage.flatMap { usage in
                guard let fetchedAt else { return usage }
                return CachedAccountUsage(usage: usage, fetchedAt: fetchedAt).current(at: context.date)
            }
            // Retain cached row geometry, but never present expired values as current.
            let windows = usage?.windows ?? []
            if windows.isEmpty {
                Text("Usage unavailable")
                    .help("No current allowance has been reported by this provider.")
            } else {
                Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                        let title = Self.name(window.durationSeconds)
                        let reset = window.resetsAt.formatted(date: .abbreviated, time: .shortened)
                        let available = current != nil && window.resetsAt > context.date
                        let description = available
                            ? "\(window.remainingPercent) percent remaining. Resets \(reset)."
                            : "Current allowance unavailable."
                        GridRow {
                            Text(title)
                                .gridColumnAlignment(.leading)
                                .fixedSize()
                            ProgressView(value: Double(window.remainingPercent), total: 100)
                                .progressViewStyle(.linear)
                                .controlSize(.mini)
                                .tint(.secondary)
                                .frame(maxWidth: .infinity)
                                .opacity(available ? 1 : 0)
                            Text(available ? "\(window.remainingPercent)%" : "—")
                                .monospacedDigit()
                                .frame(width: 32, alignment: .trailing)
                        }
                        .help("\(title): \(description)")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(title) allowance")
                        .accessibilityValue(description)
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    static func name(_ seconds: Int) -> String {
        if seconds == 604_800 { return "Weekly" }
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)-day" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)-hour" }
        return "\(max(1, seconds / 60))-min"
    }
}
