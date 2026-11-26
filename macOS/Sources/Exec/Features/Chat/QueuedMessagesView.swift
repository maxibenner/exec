import SwiftUI

struct QueuedMessagesView: View {
    let messages: [Message]
    let canCancel: Bool
    let cancel: (UUID) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(messages) { message in
                UserMessageBubble(message: message, queuedAction: .init(isEnabled: canCancel) {
                    cancel(message.id)
                })
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: TranscriptColumn.maxWidth)
        .padding(.horizontal, TranscriptColumn.horizontalInset)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }
}
