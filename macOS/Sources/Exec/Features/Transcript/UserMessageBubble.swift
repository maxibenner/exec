import AppKit
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
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(isQueued ? Color.primary : .white)
                .background(isQueued ? Color.primary.opacity(0.08) : AppColors.systemAccent, in: shape)
                .background {
                    // Keep the transcript from showing through the sidebar tint.
                    if isQueued { shape.fill(Color(nsColor: .windowBackgroundColor)) }
                }
                .frame(maxWidth: 600, alignment: .trailing)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityTitle)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder private var bubbleContents: some View {
        if let queuedAction {
            HStack(alignment: .top, spacing: 8) {
                messageContents
                Button(role: .destructive, action: queuedAction.cancel) {
                    Label("Cancel queued message", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .fixedSize()
                .help("Cancel queued message")
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
                let text = LinkedText(source: AttributedString(message.text), foregroundColor: isQueued ? .labelColor : .white)
                if isQueued {
                    // Fit short previews to the text; retain TextKit wrapping when it doesn't fit.
                    ViewThatFits(in: .horizontal) {
                        text.fixedSize(horizontal: true, vertical: false)
                        text
                    }
                } else {
                    text
                }
            }
        }
    }

    private var accessibilityTitle: Text {
        if !isQueued { return Text("You: \(message.text)") }
        if message.text.isEmpty { return Text("Queued message") }
        return Text("Queued: \(message.text)")
    }
}
