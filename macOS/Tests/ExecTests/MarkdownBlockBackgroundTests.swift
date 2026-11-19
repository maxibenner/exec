import AppKit

@MainActor struct MarkdownBlockBackgroundTests {
    func roundsNativeCodeAndTableSurfaces() throws {
        _ = NSApplication.shared
        let sources = [
            "```swift\nfirst line\n\nlast line that wraps in a narrow text container\n```",
            "```\nfirst line\nsecond line\n```",
            "| First | Second |\n| --- | ---: |\n| A long cell that wraps at narrow widths | [link](https://example.com) |\n| last | row |",
            "| Only column |\n| --- |\n| body |"
        ]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            try withAppearance(name) {
                for scale: CGFloat in [1, 2] {
                    for width: CGFloat in [180, 500] {
                        for source in sources {
                            let text = MarkdownText.render(MarkdownDocument.parse(source))
                            let view = makeView(text, width: width)
                            let layout = view.layoutManager!, container = view.textContainer!
                            let glyphs = layout.glyphRange(for: container)
                            let used = layout.usedRect(for: container)
                            let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
                            let firstCell = style.textBlocks.last as! NSTextTableBlock
                            var surface = layout.boundsRect(for: firstCell.table, at: 0, effectiveRange: nil)
                            surface.size.height -= 12 // The existing inter-block margin is not painted.
                            // A nonzero drawing origin catches container/view coordinate mixups.
                            let origin = NSPoint(x: 9, y: 7)
                            surface = surface.offsetBy(dx: origin.x, dy: origin.y)
                            let bitmap = drawBackground(view, glyphs: glyphs, origin: origin, scale: scale)
                            func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
                                bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))!.alphaComponent
                            }
                            func mirrored(_ x: CGFloat, _ y: CGFloat, right: Bool, bottom: Bool) -> NSPoint {
                                NSPoint(x: right ? surface.maxX - x : surface.minX + x,
                                        y: bottom ? surface.maxY - y : surface.minY + y)
                            }
                            for right in [false, true] {
                                for bottom in [false, true] {
                                    let corner = mirrored(1.5, 1.5, right: right, bottom: bottom)
                                    try expect(alpha(corner.x, corner.y) < 0.001)
                                    // The body needs real curved fill/stroke, not just a clipped
                                    // square border (or rounding limited to the header row).
                                    var arcAlpha: CGFloat = 0
                                    for x in 1...6 {
                                        for y in 1...6 {
                                            let point = mirrored(CGFloat(x) + 0.5, CGFloat(y) + 0.5,
                                                                 right: right, bottom: bottom)
                                            arcAlpha += alpha(point.x, point.y)
                                        }
                                    }
                                    try expect(arcAlpha > 0.01)
                                }
                            }
                            if firstCell.table.numberOfColumns == 1 && firstCell.width(for: .border, edge: .minX) == 0 {
                                // The language label, blank lines, wrapping and code body form
                                // one panel, including the padding beyond the text glyphs.
                                for y in stride(from: surface.minY + 8, through: surface.maxY - 8, by: 3) {
                                    try expect(alpha(surface.minX + 1.5, y) > 0.01)
                                    try expect(alpha(surface.midX, y) > 0.01)
                                }
                            } else if firstCell.table.numberOfColumns > 1 {
                                let divider = layout.boundsRect(for: firstCell, at: 0, effectiveRange: nil).maxX + origin.x
                                // Adjacent header cells do not get independent rounded corners.
                                try expect(alpha(divider - 2, surface.minY + 1.5) > 0.01)
                                try expect(alpha(divider + 2, surface.minY + 1.5) > 0.01)
                            }
                            try expect(alpha(surface.midX, surface.maxY + 2) < 0.001)
                            try expect(layout.usedRect(for: container) == used)
                            try expect(view.string == text.string && view.isSelectable && !view.isEditable)
                        }
                    }
                }
            }
        }
    }

    private func withAppearance(_ name: NSAppearance.Name, _ draw: () throws -> Void) throws {
        var result: Result<Void, Error> = .success(())
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            result = Result { try draw() }
        }
        try result.get()
    }

    private func makeView(_ text: NSAttributedString, width: CGFloat) -> LinkedText.TextView {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let view = LinkedText.TextView(frame: NSRect(x: 0, y: 0, width: width, height: 1000), textContainer: container)
        view.textContainerInset = .zero
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        layout.ensureLayout(for: container)
        return view
    }

    private func drawBackground(_ view: LinkedText.TextView, glyphs: NSRange, origin: NSPoint,
                                scale: CGFloat) -> NSBitmapImageRep {
        let size = view.layoutManager!.usedRect(for: view.textContainer!).size
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: Int(ceil((size.width + origin.x * 2) * scale)),
                                      pixelsHigh: Int(ceil((size.height + origin.y * 2) * scale)),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
        context.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        context.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.layoutManager!.drawBackground(forGlyphRange: glyphs, at: origin)
        return bitmap
    }
}
