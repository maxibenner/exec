import AppKit
import SwiftUI

enum AppColors {
    // Fixed iMessage blue in sRGB, independent of appearance and system accent.
    static let nativeBlue = NSColor(srgbRed: 0, green: 122.0 / 255.0, blue: 1, alpha: 1)
    static let blue = Color(nsColor: nativeBlue)

    static let subduedRed = Color.red.opacity(0.22)
    static let unavailableRed = Color.red
}
