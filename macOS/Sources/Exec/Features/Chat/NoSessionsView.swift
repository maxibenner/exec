import SwiftUI

/// The same empty state is visible before and after local session restoration.
struct NoSessionsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("No Sessions").font(.headline.bold())
                Text("Press ⌘T to create one.")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityLabel("Press Command T to create one.")
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
