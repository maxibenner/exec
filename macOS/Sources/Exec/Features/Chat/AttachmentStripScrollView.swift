import SwiftUI

/// Draft strips retain SwiftUI scrolling; sent strips pass vertical gestures to
/// the native transcript while keeping horizontal overflow reachable.
struct AttachmentStripScrollView<Content: View>: View {
    var scrollsWithTranscript: Bool
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if scrollsWithTranscript {
            TranscriptAttachmentStrip(content: content
                .foregroundStyle(.white)
                .environment(\.colorScheme, colorScheme)
                .fixedSize())
        } else {
            ScrollView(.horizontal) { content }
                .scrollIndicators(.hidden)
        }
    }
}

private struct TranscriptAttachmentStrip<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> TranscriptAttachmentScrollView<Content> {
        TranscriptAttachmentScrollView(content: content)
    }

    func updateNSView(_ view: TranscriptAttachmentScrollView<Content>, context: Context) {
        view.update(content)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TranscriptAttachmentScrollView<Content>,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.attachmentSize.width, height: nsView.attachmentSize.height)
    }
}

@MainActor final class TranscriptAttachmentScrollView<Content: View>: HorizontalContentScrollView {
    private let hosted: NSHostingView<Content>
    private(set) var attachmentSize = CGSize.zero

    init(content: Content) {
        hosted = NSHostingView(rootView: content)
        hosted.sizingOptions = [.intrinsicContentSize]
        super.init(frame: .zero)
        documentView = hosted
        measureContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ content: Content) {
        hosted.rootView = content
        measureContent()
    }

    private func measureContent() {
        attachmentSize = hosted.fittingSize
        hosted.setFrameSize(attachmentSize)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { attachmentSize }
}
