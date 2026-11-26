import SwiftUI

struct QueuedMessagesView: View {
    let messages: [Message]
    let canCancel: Bool
    let cancel: (UUID) -> Void

    var body: some View {
        QueueHeightLimit {
            ViewThatFits(in: .vertical) {
                bubbles.fixedSize(horizontal: false, vertical: true)
                ScrollView { bubbles }
                    // The bottom overlay already accounts for the transcript's scroller gutter.
                    .scrollIndicators(.never, axes: .vertical)
                    .frame(minHeight: 0, maxHeight: .infinity)
            }
        }
    }

    private var bubbles: some View {
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
    }
}

/// Cap the height offered to the fitter without reserving that space for a short queue.
private struct QueueHeightLimit: Layout {
    private let maximumHeight: CGFloat = 164

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width, height: min(proposal.height ?? maximumHeight, maximumHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(capped(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: capped(proposal))
    }
}
