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
                        // Geometry alone misses AppKit's undersized overlay-knob
                        // texture for compatible subclasses. Use its exact native class.
                        try expect(type(of: scroller) == NSScroller.self)
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

    /// Requires --composer-events' NSApplication loop. Native mouse tracking
    /// supplies hitPart; sendAction alone has no knob/track part to operate on.
    func nativeActionsPreserveReaderIntentAcrossStyles() async throws {
        _ = NSApplication.shared
        let state = TranscriptState()
        let transcript = TranscriptScrollView(state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = transcript
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { transcript.detach(); window.orderOut(nil); window.contentView = nil; window.close() }
        transcript.autohidesScrollers = false
        let messages = (0..<40).map { Message(role: .assistant, text: "Synthetic row \($0)\nSecond line") }
        func drag(_ scroller: NSScroller, to y: CGFloat) async throws {
            let knob = scroller.rect(for: .knob)
            let start = NSPoint(x: knob.midX, y: knob.midY)
            let end = NSPoint(x: knob.midX, y: y)
            for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
                let event = NSEvent.mouseEvent(with: type, location: scroller.convert(point, to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
                NSApp.postEvent(event, atStart: false)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        for style in [NSScroller.Style.overlay, .legacy, .overlay] {
            transcript.scrollerStyle = style
            transcript.tile()
            state.jumpToLatest()
            transcript.update(messages: messages, jumpRequest: state.jumpRequest)
            transcript.layoutSubtreeIfNeeded()
            transcript.refresh()
            transcript.flashScrollers()
            try await Task.sleep(for: .milliseconds(200))
            let scroller = transcript.verticalScroller!
            try expect(type(of: scroller) == NSScroller.self)
            let before = transcript.contentView.bounds.minY
            let quarter = scroller.isFlipped ? scroller.bounds.height * 0.25 : scroller.bounds.height * 0.75
            try await drag(scroller, to: quarter)
            guard transcript.contentView.bounds.minY < before, !state.followsLatest else {
                throw CheckFailure(description: "Native scroller did not stop following: style=\(style.rawValue), before=\(before), after=\(transcript.contentView.bounds.minY), follows=\(state.followsLatest)")
            }
            try await drag(scroller, to: scroller.isFlipped ? scroller.bounds.maxY : scroller.bounds.minY)
            try expect(state.followsLatest)
            try expect(abs(transcript.contentView.bounds.maxY - transcript.documentView!.bounds.maxY) <= 2)
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
