import AppKit
import SwiftUI

enum AppColors {
    // Fixed iMessage blue in sRGB, independent of appearance and system accent.
    static let nativeBlue = NSColor(srgbRed: 0, green: 122.0 / 255.0, blue: 1, alpha: 1)
    static let blue = Color(nsColor: nativeBlue)
    static var systemAccent: Color { Color(nsColor: .controlAccentColor) }
    static let systemAccentText = contrastingTextColor(on: .controlAccentColor)

    /// Keep the foreground dynamic, including in native attributed text. Resolve
    /// the background in the drawing appearance rather than caching accent RGB.
    static func contrastingTextColor(on background: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var foreground = NSColor.white
            appearance.performAsCurrentDrawingAppearance {
                guard let rgb = background.usingColorSpace(.sRGB) else { return }
                func linear(_ component: CGFloat) -> CGFloat {
                    let value = min(1, max(0, component))
                    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                // WCAG relative luminance and contrast against opaque white/black.
                let luminance = 0.2126 * linear(rgb.redComponent)
                    + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
                let whiteContrast = 1.05 / (luminance + 0.05)
                let blackContrast = (luminance + 0.05) / 0.05
                foreground = whiteContrast >= blackContrast ? .white : .black
            }
            return foreground
        }
    }

    static let subduedRed = Color.red.opacity(0.22)
    static let unavailableRed = Color.red
}
