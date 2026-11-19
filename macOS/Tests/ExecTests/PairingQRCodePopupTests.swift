import AppKit
import SwiftUI

@MainActor struct PairingQRCodePopupTests {
    func readableCodeAndStableCopyInBothAppearances() throws {
        _ = NSApplication.shared
        let code = try PairingQRCode(.object([
            "id": .string("synthetic-invitation"), "secret": .string("synthetic-only"),
            "relay": .string("wss://relay.example"), "expires": .number(2_000_000_000)
        ]))
        let pasteboard = NSPasteboard(name: .init("exec-pairing-test-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let popup = PairingQRCodePopup(code: code, pasteboard: pasteboard, dismiss: {})
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: popup.environment(\.colorScheme, scheme))
            host.frame.size = host.fittingSize
            let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            defer { window.orderOut(nil); window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            try expect(abs(host.bounds.width - 320) < 1)
            try expect(host.bounds.height > 300 && host.bounds.height < 400)

            // Render only this synthetic view. The white QR container must reach
            // the card's 24-point inset in both light and dark appearances.
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw CheckFailure(description: "Pairing popup could not render")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            for x in [32.0, 288.0] {
                guard let color = bitmap.colorAt(x: Int(x * CGFloat(bitmap.pixelsWide) / host.bounds.width),
                                                 y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else {
                    throw CheckFailure(description: "Missing pairing QR container pixels")
                }
                try expect(color.alphaComponent > 0.98)
                try expect(color.redComponent > 0.98 && color.greenComponent > 0.98 && color.blueComponent > 0.98)
            }
            for _ in 0..<2 {
                pasteboard.clearContents()
                popup.copyToClipboard()
                try expect(pasteboard.string(forType: .string) == code.text)
            }
        }
    }
}
