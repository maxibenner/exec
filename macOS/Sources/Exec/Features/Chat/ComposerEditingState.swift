import AppKit

/// Conversation-local presentation state; never persisted to disk or sent to the
/// backend. It outlives native editor remounts without retaining any views.
@MainActor final class ComposerEditingState {
    struct Position {
        let session: ObjectIdentifier
        let text: String
        let selections: [NSValue]
        let origin: NSPoint
        let width: CGFloat
        let topCharacter: Int?
        let lineOffset: CGFloat
    }
    var position: Position?
    // SwiftUI may overlap outgoing and incoming native editors during a remount.
    var owner: UUID?
}
