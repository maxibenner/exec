import AppKit
import SwiftUI

struct AttachmentScrollTests {
    @MainActor func submittedAttachmentsForwardVerticalScrolling() throws {
        let images = (0..<4).map {
            ImageAttachment(name: "Image \($0)", mediaType: "image/png", data: Data())
        }
        let files = (0..<4).map { FileAttachment(name: "Document \($0).txt") }
        try check(AttachmentStrip(images: images, scrollsWithTranscript: true), height: 84)
        try check(FileAttachmentStrip(files: files, scrollsWithTranscript: true), height: 64)
        // Even a single, non-overflowing thumbnail must not trap the wheel.
        try check(AttachmentStrip(images: [images[0]], scrollsWithTranscript: true), height: 84)
    }

    @MainActor private func check(_ content: some View, height: CGFloat) throws {
        let outer = ScrollRecorder(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 2_000))
        outer.documentView = document
        let hosted = NSHostingView(rootView: content.frame(width: 200))
        hosted.frame = NSRect(x: 0, y: 0, width: 200, height: height)
        document.addSubview(hosted)
        hosted.layoutSubtreeIfNeeded()
        try expect(abs(hosted.fittingSize.height - height) < 1)
        guard let strip = findScrollView(in: hosted) else {
            throw CheckFailure(description: "Submitted attachments need a native horizontal-only strip")
        }
        try expect(!strip.hasVerticalScroller && strip.hasHorizontalScroller)
        try expect(abs((strip.documentView?.frame.height ?? 0) - height) < 1)
        // Start at the hosted thumbnail/file surface, not just its scroll view.
        strip.documentView?.scrollWheel(with: wheel(x: 0, y: 20))
        strip.documentView?.scrollWheel(with: wheel(x: 2, y: -20))
        try expect(outer.events == 2)
        strip.scrollWheel(with: wheel(x: -20, y: 0))
        try expect(outer.events == 2)
        var proposed = strip.contentView.bounds
        proposed.origin.y = 30
        try expect(strip.contentView.constrainBoundsRect(proposed).origin.y == 0)
        strip.contentView.scroll(to: NSPoint(x: 0, y: 30))
        try expect(strip.contentView.bounds.origin.y == 0)
        if let width = strip.documentView?.frame.width, width > 200 {
            strip.contentView.scroll(to: NSPoint(x: 30, y: 0))
            try expect(strip.contentView.bounds.origin.x > 0)
        }
    }

    @MainActor private func findScrollView(in view: NSView) -> HorizontalContentScrollView? {
        (view as? HorizontalContentScrollView) ?? view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }

    private func wheel(x: Int32, y: Int32) -> NSEvent {
        NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!)!
    }

    @MainActor private final class ScrollRecorder: NSScrollView {
        var events = 0
        override func scrollWheel(with event: NSEvent) { events += 1 }
    }
}
