import AppKit
import Observation

/// Conversation-local presentation state; never persisted to disk or sent to the
/// backend. It outlives native editor remounts without retaining any views.
@MainActor @Observable final class ComposerEditingState {
    struct Position {
        let session: ObjectIdentifier
        let text: String
        let selections: [NSValue]
        let origin: NSPoint
        let width: CGFloat
        let topCharacter: Int?
        let lineOffset: CGFloat
    }
    @ObservationIgnored var position: Position?
    // SwiftUI may overlap outgoing and incoming native editors during a remount.
    // Observe ownership so a surviving editor reapplies any skipped update when
    // a temporary replacement releases the presentation.
    var owner: UUID?
}
