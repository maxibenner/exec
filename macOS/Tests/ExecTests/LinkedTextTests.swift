import AppKit

@MainActor
struct LinkedTextTests {
    func wordFadesOverlapWithoutQueuingOrChangingDuration() throws {
        var fades = StreamedWordFades()
        let burst = (0..<200).map { "word\($0)" }.joined(separator: " ")
        fades.append(burst, after: 0, at: 10)
        try expect(fades.entrances.count == 200)
        try expect(fades.entrances[0].started == 10)
        try expect(abs(fades.entrances[1].started - 10.025) < 0.000001)
        try expect(fades.entrances.allSatisfy { $0.started <= 10.1 })
        try expect(fades.entrances[100].started != fades.entrances[101].started)
        let original = fades.entrances.map(\.started)
        let next = burst + " next"
        fades.append(next, after: (burst as NSString).length, at: 10.01)
        try expect(Array(fades.entrances.dropLast().map(\.started)) == original)
        // Even the previous burst's delayed words do not hold up this arrival.
        try expect(fades.entrances.last?.started == 10.01)
        for entrance in fades.entrances {
            try expect(abs(entrance.opacity(at: entrance.started) - 0) < 0.000001)
            try expect(abs(entrance.opacity(at: entrance.started + 0.18) - 0.5) < 0.000001)
            try expect(entrance.opacity(at: entrance.started + 0.361) == 1)
        }
        fades.expire(at: 10.361)
        try expect(!fades.entrances.isEmpty)
        try expect(fades.entrances.contains { $0.started == 10.01 })
        fades.expire(at: 10.461)
        try expect(fades.entrances.isEmpty)
        fades.append(next + " slow", after: (next as NSString).length, at: 20)
        try expect(fades.entrances.count == 1)
        try expect(abs(fades.entrances[0].opacity(at: 20.18) - 0.5) < 0.000001)
    }

    func wordFadesPreservePartialWordsAndUnicode() throws {
        var fades = StreamedWordFades()
        fades.append("hel", after: 0, at: 1)
        fades.append("hello world", after: 3, at: 1.05)
        try expect(fades.entrances.count == 2)
        try expect(fades.entrances[0].range == NSRange(location: 0, length: 5))
        try expect(fades.entrances[0].started == 1)
        try expect(fades.entrances[1].started == 1.05)
        fades.expire(at: 2)
        fades.append("hello worlds", after: 11, at: 2)
        try expect(fades.entrances.count == 1) // Only the new continuation fades.
        try expect(fades.entrances[0].range == NSRange(location: 11, length: 1))

        for (partial, complete) in [("cafe", "cafe\u{301}"), ("👩", "👩🏽‍💻"), ("🇺", "🇺🇳"), ("1", "1️⃣")] {
            fades.reset()
            fades.append(partial, after: 0, at: 3)
            fades.append(complete, after: (partial as NSString).length, at: 3.1)
            try expect(fades.entrances.count == 1)
            try expect(fades.entrances[0].started == 3)
            try expect(fades.entrances[0].range == NSRange(location: 0, length: (complete as NSString).length))
        }
        fades.reset()
        let unicode = "cafe\u{301} 👨‍👩‍👧‍👦 🇺🇳 你好世界 नमस्ते — hello!"
        fades.append(unicode, after: 0, at: 4)
        let text = unicode as NSString
        try expect(fades.entrances.count > 6)
        var previousEnd = 0
        for entrance in fades.entrances {
            try expect(entrance.range.location >= previousEnd)
            try expect(text.rangeOfComposedCharacterSequences(for: entrance.range) == entrance.range)
            previousEnd = NSMaxRange(entrance.range)
        }
        fades.reset()
        let combiningSpace = "old \u{301}new"
        fades.append(combiningSpace, after: 4, at: 5)
        for entrance in fades.entrances {
            try expect((combiningSpace as NSString).rangeOfComposedCharacterSequences(for: entrance.range) == entrance.range)
        }
        fades.reset()
        fades.append("history continued", after: 7, at: 5)
        try expect(fades.entrances.count == 1)
        try expect(fades.entrances[0].range.location == 8)
    }

    func nativeWordFadesPreserveLayoutAndStopOnDetach() throws {
        let storage = NSTextStorage()
        let layout = StreamedTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 240, height: 1000))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = LinkedText.TextView(frame: NSRect(x: 0, y: 0, width: 240, height: 1000), textContainer: container)
        view.textContainerInset = .zero
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.animatesStreamedText = true
        func text(_ source: String) -> NSAttributedString { LinkedText.attributed(AttributedString(source)) }
        view.update(text("History")) // Initial mount, even already attached, is static.
        try expect(layout.fades.entrances.isEmpty && !layout.hasAnimationClock)
        view.setSelectedRange(NSRange(location: 0, length: 4))
        let source = "History newly streamed words that wrap across several lines in the native text container."
        view.update(text(source))
        try expect(view.string == source && storage.length == (source as NSString).length)
        try expect(view.selectedRange() == NSRange(location: 0, length: 4))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            try expect(layout.fades.entrances.count > 5 && !layout.hasAnimationClock)
            _ = drawGlyphs(layout, container: container)
            try expect(layout.hasAnimationClock)
        } else {
            try expect(layout.fades.entrances.isEmpty && !layout.hasAnimationClock)
        }
        let starts = layout.fades.entrances.map(\.started)
        for width: CGFloat in [180, 360] {
            view.setFrameSize(NSSize(width: width, height: 1000))
            try expect(ceil(layout.usedRect(for: container).height) == LinkedText.measuredSize(of: text(source), width: width).height)
            try expect(layout.fades.entrances.map(\.started) == starts)
        }
        let restyled = NSMutableAttributedString(attributedString: text(source))
        restyled.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: restyled.length))
        view.update(restyled)
        try expect(layout.fades.entrances.map(\.started) == starts)
        view.removeFromSuperview()
        try expect(layout.fades.entrances.isEmpty && !layout.hasAnimationClock)
        window.contentView = view
        view.update(text(source + " caught up while detached"))
        try expect(layout.fades.entrances.isEmpty && !layout.hasAnimationClock)
        view.update(text(source + " caught up while detached more"))
        let completing = layout.fades.entrances.map(\.started)
        view.animatesStreamedText = false
        view.update(text(source + " caught up while detached more"))
        try expect(layout.fades.entrances.map(\.started) == completing)
        view.animatesStreamedText = true
        view.update(text(source + " more again"))
        view.update(text("Replacement history"))
        try expect(layout.fades.entrances.isEmpty && !layout.hasAnimationClock)
    }

    func firstPaintAndCompletionKeepNativeFades() async throws {
        let storage = NSTextStorage()
        let layout = StreamedTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 240, height: 1000))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let view = LinkedText.TextView(frame: NSRect(x: 0, y: 0, width: 240, height: 1000), textContainer: container)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        defer { window.contentView = nil }
        view.animatesStreamedText = true
        view.revealsInitialStreamedText = true
        view.update(LinkedText.attributed(AttributedString("First words"))) // Before attachment.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            try expect(layout.fades.entrances.isEmpty)
            return
        }
        try expect(layout.fades.entrances.count == 2 && !layout.hasAnimationClock)
        try await Task.sleep(for: .milliseconds(40)) // Layout/mount delay must consume no fade time.
        try expect(layout.fades.entrances.allSatisfy { $0.waitingForPaint && $0.opacity(at: 1_000_000) == 0 })
        window.contentView = view // Only now may AppKit schedule the first native draw.
        try expect(drawGlyphs(layout, container: container) == 0) // Actual first glyph pixels, not just timing math.
        let starts = layout.fades.entrances.map(\.started)
        try expect(layout.hasAnimationClock && layout.fades.entrances.allSatisfy { !$0.waitingForPaint })
        view.animatesStreamedText = false
        view.update(LinkedText.attributed(AttributedString("First words!")))
        try expect(Array(layout.fades.entrances.prefix(2).map(\.started)) == starts)
        try expect(layout.hasAnimationClock)
        _ = drawGlyphs(layout, container: container) // Paint the final punctuation, too.
        try await Task.sleep(for: .milliseconds(500))
        try expect(layout.fades.entrances.isEmpty && !layout.hasAnimationClock)
        try expect(drawGlyphs(layout, container: container) > 0) // Natural completion makes the glyphs opaque.
    }

    func renderedEditsRetainFadesAndCodeAppendPositions() throws {
        var fades = StreamedWordFades()
        let old = "Before `partial"
        fades.append(old, after: 7, at: 10)
        let new = "Before partial"
        fades.edit(from: old, to: new, edit: RenderedTextEdit(from: old, to: new), animatesNewText: false, at: 10.1)
        try expect(fades.entrances.count == 1)
        try expect(fades.entrances[0].range == NSRange(location: 7, length: 7))
        try expect(fades.entrances[0].started == 10.025)
        let code = "swift\nlet val\n", appended = "swift\nlet value = 1\n"
        fades.reset()
        fades.append(code, after: 0, at: 20)
        let edit = RenderedTextEdit(from: code, to: appended)
        try expect(edit.oldRange == NSRange(location: 13, length: 0))
        fades.edit(from: code, to: appended, edit: edit, animatesNewText: true, at: 20.1)
        try expect(fades.entrances.contains { $0.range == NSRange(location: 10, length: 5) && $0.started == 20.05 })
        try expect(fades.entrances.contains { $0.range == NSRange(location: 18, length: 1) && $0.waitingForPaint })
        try expect(fades.entrances.allSatisfy { NSMaxRange($0.range) < (appended as NSString).length })
    }

    private func drawGlyphs(_ layout: NSLayoutManager, container: NSTextContainer) -> Int {
        layout.ensureLayout(for: container)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 240, height: 200))
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: .zero)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return (0..<200).reduce(0) { total, y in
            total + (0..<240).reduce(0) { $0 + Int(bitmap.bitmapData![y * bitmap.bytesPerRow + $1 * 4 + 3]) }
        }
    }

    func measuresWrappingAcrossWidthsAndUpdates() throws {
        // Markdown must not reserve an extra empty line after ordinary replies.
        let source = "That confirms the fix is the latest commit. One more call below to check whether the placement stays consistent."
        let rendered = MarkdownText.render(MarkdownDocument.parse(source))
        let plain = LinkedText.attributed(AttributedString(source))
        try expect(rendered.string == source)
        for width: CGFloat in [390, 750] {
            try expect(LinkedText.measuredSize(of: rendered, width: width).height ==
                       LinkedText.measuredSize(of: plain, width: width).height)
        }
        let paragraphs = MarkdownText.render(MarkdownDocument.parse("First paragraph.\n\nSecond paragraph."))
        try expect(paragraphs.string == "First paragraph.\nSecond paragraph.")
        let firstStyle = paragraphs.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        let lastStyle = paragraphs.attribute(.paragraphStyle, at: paragraphs.length - 1, effectiveRange: nil) as! NSParagraphStyle
        try expect(firstStyle.paragraphSpacing == 10 && lastStyle.paragraphSpacing == 0)
        for source in ["```\ncode\n```", "| A | B |\n| --- | --- |\n| one | two |"] {
            let boxed = MarkdownText.render(MarkdownDocument.parse(source))
            try expect(boxed.string.hasSuffix("\n"))
            try expect(LinkedText.measuredSize(of: boxed, width: 750).height > 0)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let text = NSMutableAttributedString(
            string: "I couldn’t retrieve issue #7: the public lookup returned 404, which can happen if the repository is private. The local workspace does contain the project, so I can inspect the relevant code once I have the issue details.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                         .paragraphStyle: paragraph])
        text.addAttribute(.link, value: URL(string: "https://example.com/7")!,
                          range: NSRange(location: 19, length: 8))
        let wide = LinkedText.measuredSize(of: text, width: 750)
        let narrow = LinkedText.measuredSize(of: text, width: 390)
        try expect(narrow.height > wide.height)
        try expect(LinkedText.measuredSize(of: text, width: 750) == wide)

        // Compare the reserved height against actual TextKit layout at each final width.
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 750, height: 1000))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(text)
        for width: CGFloat in [750, 390, 600] {
            view.setFrameSize(NSSize(width: width, height: 1000))
            let container = view.textContainer!
            let layout = view.layoutManager!
            layout.ensureLayout(for: container)
            let measured = LinkedText.measuredSize(of: text, width: width)
            try expect(measured.height == ceil(layout.usedRect(for: container).height))
        }

        let measurement = LinkedTextMeasurement()
        measurement.update(text)
        try expect(measurement.size(width: 390) == narrow)
        try expect(measurement.size(width: 750) == wide)
        try expect(measurement.size(width: 390) == narrow)
        // Evict old widths, then verify recomputation still agrees with fresh layout.
        for width in 400...420 { _ = measurement.size(width: CGFloat(width)) }
        try expect(measurement.size(width: 390) == narrow)

        text.append(text.copy() as! NSAttributedString)
        measurement.update(text)
        try expect(measurement.size(width: 390).height > narrow.height)
        text.addAttribute(.font, value: NSFont.systemFont(ofSize: 24), range: NSRange(location: 0, length: text.length))
        measurement.update(text)
        try expect(measurement.size(width: 390) == LinkedText.measuredSize(of: text, width: 390))
    }
}
