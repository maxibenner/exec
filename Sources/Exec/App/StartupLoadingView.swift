import SwiftUI

/// One grace period spans account setup and local session restoration. Removing
/// this view cancels the delay; fast launches never mount a progress indicator.
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
