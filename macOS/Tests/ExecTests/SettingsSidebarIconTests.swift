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
}
