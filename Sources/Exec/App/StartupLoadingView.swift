import SwiftUI

/// Only covers initial local credential/store setup (including a possible Keychain
/// permission prompt). Session restoration and remote refresh use the real UI.
struct StartupLoadingView: View {
    @State private var showsProgress = false

    var body: some View {
        ZStack {
            Color.clear
            if showsProgress {
                ProgressView().accessibilityLabel("Opening Exec")
            }
        }
        .task {
            showsProgress = false
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard !Task.isCancelled else { return }
            showsProgress = true
        }
    }
}
