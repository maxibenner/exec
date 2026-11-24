#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit) || canImport(AppKit)
/// Foreground-only syntax colors shared by both native transcript renderers.
@MainActor public enum SyntaxPalette {
    #if canImport(UIKit)
    private typealias NativeColor = UIColor
    #else
    private typealias NativeColor = NSColor
    #endif

    // Reuse dynamic colors across tokens and updates rather than allocating one per span.
    private static let palette = Dictionary(uniqueKeysWithValues: SyntaxToken.Kind.allCases.map { ($0, makeColor(for: $0)) })

    #if canImport(UIKit)
    public static func color(for kind: SyntaxToken.Kind) -> UIColor { palette[kind]! }
    private static func makeColor(for kind: SyntaxToken.Kind) -> NativeColor {
        if kind == .operator { return .label }
        if kind == .punctuation { return .secondaryLabel }
        let pair = colors(for: kind)
        return UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? pair.dark : pair.light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }
    #elseif canImport(AppKit)
    public static func color(for kind: SyntaxToken.Kind) -> NSColor { palette[kind]! }
    private static func makeColor(for kind: SyntaxToken.Kind) -> NativeColor {
        if kind == .operator { return .labelColor }
        if kind == .punctuation { return .secondaryLabelColor }
        let pair = colors(for: kind)
        return NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let rgb = dark ? pair.dark : pair.light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
    }
    #endif

    private static func colors(for kind: SyntaxToken.Kind) -> (light: UInt32, dark: UInt32) {
        switch kind {
        case .keyword: (0x8F2994, 0xE887EF)
        case .string: (0xA82E29, 0xFA9278)
        case .comment: (0x576B59, 0x87A18A)
        case .number: (0x2947B5, 0xB0B3FC)
        case .type: (0x196B78, 0x7ACFD6)
        case .function: (0x61409E, 0xC2A6EF)
        case .property: (0x33618C, 0x91C2ED)
        case .constant: (0x914D17, 0xF2BA73)
        case .operator, .punctuation: (0x333333, 0xDDDDDD)
        }
    }
}
#endif
