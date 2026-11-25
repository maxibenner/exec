import AppKit

@MainActor struct SettingsSidebarIconTests {
    func nativeSymbolsRetainIdentityAndAdaptToRowStyle() throws {
        _ = NSApplication.shared
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 200, height: 32))
        let icon = SettingsSidebarImageView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        cell.addSubview(icon)
        icon.configure(systemName: "gearshape", accent: .systemOrange, isActive: true)
        guard let image = icon.image else { throw CheckFailure(description: "Missing native settings symbol") }
        try expect(!icon.allowsVibrancy && icon.contentTintColor == .systemOrange)
        try expect(icon.cell?.backgroundStyle == .normal)

        cell.backgroundStyle = .emphasized
        icon.configure(systemName: "gearshape", accent: .systemOrange, isActive: true)
        try expect(icon.image === image && icon.contentTintColor == .labelColor)
        try expect(icon.cell?.backgroundStyle == .emphasized)

        // Focus and appearance change the drawing context, not the symbol/view.
        cell.backgroundStyle = .normal
        icon.synchronizeBackgroundStyle()
        try expect(icon.image === image && icon.cell?.backgroundStyle == .normal)
        try expect(icon.contentTintColor == .systemOrange)
        icon.configure(systemName: "gearshape", accent: .systemPurple, isActive: true)
        try expect(icon.image === image && icon.contentTintColor == .systemPurple)
        icon.configure(systemName: "gearshape", accent: .systemPurple, isActive: false)
        try expect(icon.image === image && icon.contentTintColor == .secondaryLabelColor)
    }

    func nativeSymbolsPaintAccentAndSelectedForeground() throws {
        _ = NSApplication.shared
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 96, height: 96))
        let icon = SettingsSidebarImageView(frame: cell.bounds)
        icon.imageScaling = .scaleProportionallyUpOrDown
        cell.addSubview(icon)
        icon.configure(systemName: "gearshape", accent: .systemOrange, isActive: true)
        let original = icon.image
        try expectPaintedColor(icon, expected: .systemOrange)

        cell.backgroundStyle = .emphasized
        icon.synchronizeBackgroundStyle()
        try expect(icon.symbolConfiguration == nil)
        try expectPaintedColor(icon, expected: .alternateSelectedControlTextColor)

        cell.backgroundStyle = .normal
        icon.configure(systemName: "gearshape", accent: .systemBlue, isActive: true)
        try expectPaintedColor(icon, expected: .systemBlue)
        try expect(icon.image === original)
        icon.configure(systemName: "gearshape", accent: .systemBlue, isActive: false)
        try expect(icon.symbolConfiguration == nil)
    }

    private func expectPaintedColor(_ icon: SettingsSidebarImageView, expected: NSColor) throws {
        // Paint only this test-owned symbol cell, never a window or screen snapshot.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap), let cell = icon.cell else {
            throw CheckFailure(description: "Cannot create symbol paint fixture")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        var target: NSColor?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            NSColor.clear.setFill()
            icon.bounds.fill(using: .copy)
            target = expected.usingColorSpace(.sRGB)
            cell.draw(withFrame: icon.bounds, in: icon)
        }
        guard let target else { throw CheckFailure(description: "Missing expected symbol color") }
        var opaque = 0, matching = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.6 else { continue }
                opaque += 1
                if abs(color.redComponent - target.redComponent) < 0.1 &&
                    abs(color.greenComponent - target.greenComponent) < 0.1 &&
                    abs(color.blueComponent - target.blueComponent) < 0.1 { matching += 1 }
            }
        }
        try expect(opaque > 20 && Double(matching) / Double(opaque) > 0.9)
    }
}
