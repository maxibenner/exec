import AppKit

@MainActor struct AppColorsTests {
    func choosesAccessibleTextForLightAndDarkColors() throws {
        // Known sRGB luminances include mid-gray (which must be linearized)
        // and saturated colors (which must use the WCAG channel weights).
        let fixtures: [(red: CGFloat, green: CGFloat, blue: CGFloat, luminance: CGFloat, white: Bool)] = [
            (0, 0, 0, 0, true),
            (1, 1, 1, 1, false),
            (1, 1, 0, 0.9278, false),
            (1, 0, 0, 0.2126, false),
            (0, 0, 1, 0.0722, true),
            (0.5, 0.5, 0.5, 0.214041, false),
            (0.45, 0.45, 0.45, 0.170645, true),
            (0.04, 0.04, 0.04, 0.003096, true)
        ]
        for fixture in fixtures {
            let background = NSColor(srgbRed: fixture.red, green: fixture.green, blue: fixture.blue, alpha: 1)
            let foreground = try resolved(AppColors.contrastingTextColor(on: background), in: .aqua)
            let component: CGFloat = fixture.white ? 1 : 0
            try expect(foreground.redComponent == component && foreground.greenComponent == component
                && foreground.blueComponent == component && foreground.alphaComponent == 1)
            let whiteContrast = 1.05 / (fixture.luminance + 0.05)
            let blackContrast = (fixture.luminance + 0.05) / 0.05
            let chosenContrast = fixture.white ? whiteContrast : blackContrast
            try expect(chosenContrast >= 4.5 && chosenContrast >= (fixture.white ? blackContrast : whiteContrast))
        }
    }

    func foregroundResolvesDynamicallyInTheDrawingAppearance() throws {
        let background = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
        }
        let foreground = AppColors.contrastingTextColor(on: background)
        // Reuse the same color, just as native attributed text and SwiftUI do.
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            let rgb = try resolved(foreground, in: appearance)
            let expected: CGFloat = appearance == .darkAqua ? 1 : 0
            try expect(rgb.redComponent == expected && rgb.greenComponent == expected && rgb.blueComponent == expected)
            let accentText = try resolved(AppColors.systemAccentText, in: appearance)
            let expectedAccentText = try resolved(AppColors.contrastingTextColor(on: .controlAccentColor), in: appearance)
            try expect(accentText == expectedAccentText)
        }
    }

    private func resolved(_ color: NSColor, in name: NSAppearance.Name) throws -> NSColor {
        var rgb: NSColor?
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            rgb = color.usingColorSpace(.sRGB)
        }
        guard let rgb else { throw CheckFailure(description: "Could not resolve color in sRGB") }
        return rgb
    }
}
