import AppKit

@MainActor struct TranscriptScrollerTests {
    func keepsTheFullNativeKnobAndHitGeometryAcrossStylesAndResizes() throws {
        _ = NSApplication.shared
        let transcript = TranscriptScrollView(state: TranscriptState())
        defer { transcript.detach() }
        // An offscreen clipping ancestor models the pane boundary, not the desktop.
        let pane = NSView()
        pane.clipsToBounds = true
        pane.addSubview(transcript)
        let native = NSScrollView()
        native.borderType = .noBorder
        native.drawsBackground = false
        native.automaticallyAdjustsContentInsets = false
        native.hasVerticalScroller = true
        native.documentView = NSView()
        transcript.autohidesScrollers = false
        native.autohidesScrollers = false
        let messages = (0..<40).map { Message(role: .assistant, text: "Transcript row \($0)\nSecond line.") }

        // Change styles, appearances and widths on the same production scroller.
        // Per-view styles leave the user's Show Scroll Bars preference untouched.
        for style in [NSScroller.Style.overlay, .legacy, .overlay] {
            transcript.scrollerStyle = style
            native.scrollerStyle = style
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                transcript.appearance = NSAppearance(named: appearance)
                native.appearance = NSAppearance(named: appearance)
                for width: CGFloat in [900, 400, 640] {
                    pane.frame.size = NSSize(width: width, height: 600)
                    transcript.frame = pane.bounds
                    let header: CGFloat = width == 400 ? 52 : 0
                    transcript.updateHeaderInset(header)
                    transcript.tile()
                    transcript.update(messages: messages, jumpRequest: 0)
                    transcript.layoutSubtreeIfNeeded()
                    transcript.refresh()
                    native.frame = transcript.frame
                    native.scrollerInsets.top = header
                    native.documentView!.frame = transcript.documentView!.frame
                    native.tile()
                    let scroller = transcript.verticalScroller!
                    let reference = native.verticalScroller!
                    // Use the real document/viewport proportion, away from either end.
                    scroller.doubleValue = 0.5
                    reference.doubleValue = scroller.doubleValue
                    reference.knobProportion = scroller.knobProportion
                    do {
                        try expect(transcript.scrollerStyle == style && scroller.scrollerStyle == style)
                        try expect(!scroller.isHidden && scroller.isEnabled)
                        try expect(scroller.frame == reference.frame && scroller.bounds == reference.bounds)
                        try expect(transcript.contentSize == native.contentSize)
                        let knob = scroller.rect(for: .knob)
                        try expect(!knob.isEmpty && knob == reference.rect(for: .knob))
                        try expect(scroller.visibleRect.contains(knob))
                        try expect(pane.bounds.contains(scroller.convert(knob, to: pane)))
                        // testPart takes window/base coordinates, even offscreen.
                        // Both sides of the full knob must remain draggable, not just its center.
                        for x in [knob.minX + 0.5, knob.midX, knob.maxX - 0.5] {
                            let point = scroller.convert(NSPoint(x: x, y: knob.midY), to: nil)
                            try expect(scroller.testPart(point) == .knob)
                        }
                        for scale in [1, 2] {
                            let pixels = try knobAlpha(scroller, scale: scale)
                            // Compare against this OS's native drawing, not a golden image.
                            try expect(pixels == knobAlpha(reference, scale: scale))
                            try expect(pixels.contains { $0 > 0 })
                            let pixelWidth = Int(scroller.bounds.width) * scale
                            // Include the stroke/shadow outside rect(for: .knob): neither
                            // side of the actual rendered indicator may touch the clip edge.
                            for row in stride(from: 0, to: pixels.count, by: pixelWidth) {
                                try expect(pixels[row] == 0 && pixels[row + pixelWidth - 1] == 0)
                            }
                        }
                    } catch {
                        throw CheckFailure(description: "Scroller style=\(style.rawValue), \(appearance.rawValue), width=\(width): \(error)")
                    }
                }
            }
        }
    }

    private func knobAlpha(_ scroller: NSScroller, scale: Int) throws -> [UInt8] {
        let width = Int(scroller.bounds.width) * scale
        let height = Int(scroller.bounds.height) * scale
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32),
              let bytes = bitmap.bitmapData, let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CheckFailure(description: "Could not render offscreen scrollbar knob")
        }
        bytes.initialize(repeating: 0, count: bitmap.bytesPerRow * height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.cgContext.clip(to: scroller.visibleRect)
        scroller.effectiveAppearance.performAsCurrentDrawingAppearance { scroller.drawKnob() }
        return stride(from: 3, to: bitmap.bytesPerRow * height, by: 4).map { bytes[$0] }
    }
}
