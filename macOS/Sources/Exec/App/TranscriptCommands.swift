import SwiftUI

enum MessageNavigationDirection {
    case previous, next
}

private struct TranscriptNavigationKey: FocusedValueKey {
    typealias Value = TranscriptState
}

extension FocusedValues {
    var transcriptNavigation: TranscriptState? {
        get { self[TranscriptNavigationKey.self] }
        set { self[TranscriptNavigationKey.self] = newValue }
    }
}

struct TranscriptCommands: Commands {
    @FocusedValue(\.transcriptNavigation) private var transcript

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Previous Sent Message") { transcript?.scrollView?.navigateSentMessage(.previous) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(transcript == nil)
            Button("Next Sent Message") { transcript?.scrollView?.navigateSentMessage(.next) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(transcript == nil)
        }
    }
}
