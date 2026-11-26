import AppKit
import ExecTranscript
import SwiftUI

struct UserMessageBubble: View {
    struct QueuedAction {
        let isEnabled: Bool
        let cancel: () -> Void
    }

    let message: Message
    var queuedAction: QueuedAction?

    private var isQueued: Bool { queuedAction != nil }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10) }

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            bubbleContents
                .foregroundStyle(isQueued ? Color.primary : .white)
                .background {
                    if isQueued {
                        shape.fill(Color(nsColor: .windowBackgroundColor))
                            .overlay { shape.fill(ToolCardAppearance.fill) }
                            .overlay { shape.strokeBorder(Color(nsColor: .separatorColor)) }
                    } else {
                        shape.fill(AppColors.systemAccent)
                    }
                }
                .frame(maxWidth: 600, alignment: .trailing)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityTitle)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private var bubbleContents: some View {
        if let queuedAction {
            HStack(alignment: .top, spacing: 4) {
                messageContents
                ChatRemoveButton(label: "Cancel queued message", role: .destructive, delaysDimming: true,
                                 action: queuedAction.cancel)
                    .disabled(!queuedAction.isEnabled)
            }
        } else {
            messageContents
        }
    }

    private var messageContents: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !message.images.isEmpty {
                AttachmentStrip(images: message.images, scrollsWithTranscript: !isQueued)
            }
            if !message.files.isEmpty {
                FileAttachmentStrip(files: message.files, scrollsWithTranscript: !isQueued)
            }
            if !message.text.isEmpty {
                if isQueued {
                    QueuedBubbleText(text: message.text).equatable()
                } else {
                    LinkedText(source: AttributedString(message.text), foregroundColor: .white)
                }
            }
        }
        .padding(isQueued ? .leading : .horizontal, 12)
        .padding(.vertical, 8)
    }

    private var accessibilityTitle: Text {
        if !isQueued { return Text("You: \(message.text)") }
        if message.text.isEmpty { return Text("Queued message") }
        return Text("Queued: \(message.text)")
    }
}

private struct QueuedBubbleText: View, Equatable {
    let text: String

    var body: some View {
        LinkedText(source: AttributedString(text), fitsContentWidth: true)
    }
}
