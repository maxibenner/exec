import AppKit

@MainActor
struct LinkedTextTests {
    func lineFadesShareBatchEpochAndNeverQueue() throws {
        let view = makeTextView()
        let burst = (0..<200).map { "word\($0)" }.joined(separator: " ")
        view.update(LinkedText.attributed(AttributedString(burst)))
        let lines = visualLines(in: view)
        try expect(lines.count > 10 && !burst.contains("\n")) // Real wrapped lines, not paragraphs.
        var fades = StreamedLineFades()
        fades.edit(oldLength: 0, edit: RenderedTextEdit(from: "", to: burst), animatesNewText: true, at: 1)
        fades.beginDrawing(lines[0], at: 10) { fresh in
            lines.map { NSIntersectionRange(fresh, $0) }.filter { $0.length > 0 }
        }
        try expect(fades.entrances.map(\.range) == lines)
        let starts = fades.entrances.map(\.started)
        try expect(starts[0] == 10 && abs(starts[1] - 10.025) < 0.000001)
        try expect(starts == starts.sorted() && starts.allSatisfy { $0 <= 10.1 })
        fades.beginDrawing(lines.last!, at: 10.2) { [$0] }
        try expect(fades.entrances.map(\.started) == starts) // Different dirty range, same batch epoch.
        let next = burst + " continuation"
        fades.edit(oldLength: (burst as NSString).length, edit: RenderedTextEdit(from: burst, to: next),
                   animatesNewText: true, at: 10.35)
        let fresh = fades.entrances.last!.range
        fades.beginDrawing(fresh, at: 10.35) { [$0] }
        try expect(Array(fades.entrances.dropLast().map(\.started)) == starts)
        try expect(fades.entrances.last!.started == 10.35)
        try expect(fresh == NSRange(location: (burst as NSString).length, length: 13))
        // Every fresh line/continuation has a full 360 ms; none inherits an
        // almost-complete fade or waits for earlier lines to finish.
        for entrance in fades.entrances {
            try expect(entrance.opacity(at: entrance.started) == 0)
            try expect(abs(entrance.opacity(at: entrance.started + 0.18) - 0.5) < 0.000001)
            try expect(entrance.opacity(at: entrance.started + 0.361) == 1)
        }
        fades.expire(at: 10.711)
        try expect(fades.entrances.isEmpty)
    }

    func nativeWrappedLinesAndFreshContinuations() throws {
        let view = makeTextView()
        let layout = view.layoutManager as! StreamedTextLayoutManager
        let container = view.textContainer!
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        defer { window.contentView = nil }
        view.animatesStreamedText = true
        view.revealsInitialStreamedText = true
        let source = "All words on each visual line fade together without a left to right wipe. A partial last line"
        view.update(LinkedText.attributed(AttributedString(source)))
        window.contentView = view
        let lines = visualLines(in: view)
        try expect(lines.count >= 3)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let firstGlyphs = layout.glyphRange(forCharacterRange: lines[0], actualCharacterRange: nil)
        try expect(drawGlyphs(layout, container: container, range: firstGlyphs) == 0)
        try expect(layout.fades.entrances.map(\.range) == lines)
        let starts = layout.fades.entrances.map(\.started)
        try expect(layout.fades.entrances.allSatisfy { !$0.waitingForPaint })
        _ = drawGlyphs(layout, container: container, range:
            layout.glyphRange(forCharacterRange: lines.last!, actualCharacterRange: nil))
        try expect(layout.fades.entrances.map(\.started) == starts)
        view.setSelectedRange(NSRange(location: 0, length: 8))
        view.update(LinkedText.attributed(AttributedString(source + " continues")))
        let fresh = layout.fades.entrances.last!
        try expect(fresh.range == NSRange(location: (source as NSString).length, length: 10))
        try expect(fresh.waitingForPaint && fresh.opacity(at: .greatestFiniteMagnitude) == 0)
        _ = drawGlyphs(layout, container: container)
        try expect(Array(layout.fades.entrances.prefix(lines.count).map(\.started)) == starts)
        try expect(layout.fades.entrances.last!.started >= starts[0])
        try expect(view.selectedRange() == NSRange(location: 0, length: 8))
        try expect(view.string == source + " continues") // Full content exists before reveal.

        // TextKit, not custom word/grapheme tokenization, owns Unicode shaping.
        for (partial, complete) in [("cafe", "cafe\u{301}"), ("👩", "👩🏽‍💻"), ("🇺", "🇺🇳"), ("1", "1️⃣")] {
            view.update(LinkedText.attributed(AttributedString("History " + partial)))
            view.update(LinkedText.attributed(AttributedString("History " + complete)))
            _ = drawGlyphs(layout, container: container)
            try expect(view.string == "History " + complete)
            try expect(layout.fades.entrances.allSatisfy { NSMaxRange($0.range) <= view.textStorage!.length })
        }
    }

    func nativeLineFadesPreserveLayoutAndStopOnDetach() throws {
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
            try expect(layout.fades.entrances.count == 1 && !layout.hasAnimationClock)
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
        try expect(layout.fades.entrances.count == 1 && !layout.hasAnimationClock)
        try await Task.sleep(for: .milliseconds(40)) // Layout/mount delay must consume no fade time.
        try expect(layout.fades.entrances.allSatisfy { $0.waitingForPaint && $0.opacity(at: 1_000_000) == 0 })
        window.contentView = view // Only now may AppKit schedule the first native draw.
        try expect(drawGlyphs(layout, container: container) == 0) // Actual first glyph pixels, not just timing math.
        let starts = layout.fades.entrances.map(\.started)
        try expect(layout.hasAnimationClock && layout.fades.entrances.allSatisfy { !$0.waitingForPaint })
        view.animatesStreamedText = false
        view.update(LinkedText.attributed(AttributedString("First words!")))
        try expect(Array(layout.fades.entrances.prefix(1).map(\.started)) == starts)
        try expect(layout.hasAnimationClock)
        _ = drawGlyphs(layout, container: container) // Paint the final punctuation, too.
        try await Task.sleep(for: .milliseconds(500))
        try expect(layout.fades.entrances.isEmpty && !layout.hasAnimationClock)
        try expect(drawGlyphs(layout, container: container) > 0) // Natural completion makes the glyphs opaque.
    }

    func renderedEditsRetainFadesAndCodeAppendPositions() throws {
        var fades = StreamedLineFades()
        let old = "Before `partial"
        fades.edit(oldLength: 7, edit: RenderedTextEdit(from: "Before ", to: old), animatesNewText: true, at: 10)
        fades.beginDrawing(NSRange(location: 0, length: 15), at: 10) { [$0] }
        let new = "Before partial"
        fades.edit(oldLength: (old as NSString).length, edit: RenderedTextEdit(from: old, to: new),
                   animatesNewText: false, at: 10.1)
        try expect(fades.entrances.count == 1)
        try expect(fades.entrances[0].range == NSRange(location: 7, length: 7))
        try expect(fades.entrances[0].started == 10)
        let code = "swift\nlet val\n", appended = "swift\nlet value = 1\n"
        fades.reset()
        fades.edit(oldLength: 0, edit: RenderedTextEdit(from: "", to: code), animatesNewText: true, at: 20)
        fades.beginDrawing(NSRange(location: 0, length: 14), at: 20) { _ in
            [NSRange(location: 0, length: 6), NSRange(location: 6, length: 8)]
        }
        let edit = RenderedTextEdit(from: code, to: appended)
        try expect(edit.oldRange == NSRange(location: 13, length: 0))
        fades.edit(oldLength: (code as NSString).length, edit: edit, animatesNewText: true, at: 20.1)
        try expect(fades.entrances.contains { $0.range == NSRange(location: 6, length: 7) && $0.started == 20.025 })
        try expect(fades.entrances.contains { $0.range == NSRange(location: 13, length: 6) && $0.waitingForPaint })
        try expect(fades.entrances.contains { $0.range == NSRange(location: 19, length: 1) && $0.started == 20.025 })
    }

    private func makeTextView() -> LinkedText.TextView {
        let storage = NSTextStorage()
        let layout = StreamedTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 240, height: 1000))
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        let view = LinkedText.TextView(frame: NSRect(x: 0, y: 0, width: 240, height: 1000), textContainer: container)
        view.textContainerInset = .zero
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        return view
    }

    private func visualLines(in view: LinkedText.TextView) -> [NSRange] {
        let layout = view.layoutManager!, container = view.textContainer!
        layout.ensureLayout(for: container)
        var lines: [NSRange] = []
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, range, _ in
            lines.append(layout.characterRange(forGlyphRange: range, actualGlyphRange: nil))
        }
        return lines
    }

    private func drawGlyphs(_ layout: NSLayoutManager, container: NSTextContainer, range: NSRange? = nil) -> Int {
        layout.ensureLayout(for: container)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 240, height: 200))
        layout.drawGlyphs(forGlyphRange: range ?? layout.glyphRange(for: container), at: .zero)
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
