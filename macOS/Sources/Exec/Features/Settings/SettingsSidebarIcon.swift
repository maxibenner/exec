import AppKit
import SwiftUI

/// Keep SwiftUI's symbol metrics, but use one native renderer across row-emphasis changes.
struct SettingsSidebarIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .hidden()
            .overlay {
                SettingsSidebarNativeImage(systemName: systemName)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct SettingsSidebarNativeImage: NSViewRepresentable {
    let systemName: String

    func makeNSView(context: Context) -> SettingsSidebarImageView {
        let view = SettingsSidebarImageView(frame: .zero)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: SettingsSidebarImageView, context: Context) {
        let accent = NSColor(Color(Color.accentColor.resolve(in: context.environment)))
        view.configure(systemName: systemName, accent: accent,
                       isActive: context.environment.controlActiveState != .inactive)
        view.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsSidebarImageView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }
}

final class SettingsSidebarImageView: NSImageView {
    private var systemName: String?
    private var accent = NSColor.controlAccentColor
    private var isActive = true

    // The sidebar supplies its material. Avoid SwiftUI's separate vibrant symbol layers.
    override var allowsVibrancy: Bool { false }

    func configure(systemName: String, accent: NSColor, isActive: Bool) {
        if self.systemName != systemName {
            self.systemName = systemName
            image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
        }
        self.accent = accent
        self.isActive = isActive
        synchronizeBackgroundStyle()
        needsDisplay = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        synchronizeBackgroundStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        synchronizeBackgroundStyle()
    }

    override func draw(_ dirtyRect: NSRect) {
        synchronizeBackgroundStyle()
        super.draw(dirtyRect)
    }

    func synchronizeBackgroundStyle() {
        var style: NSView.BackgroundStyle = .normal
        var ancestor = superview
        while let view = ancestor {
            if let tableCell = view as? NSTableCellView {
                style = tableCell.backgroundStyle
                break
            }
            if let row = view as? NSTableRowView {
                style = row.interiorBackgroundStyle
                break
            }
            ancestor = view.superview
        }
        if cell?.backgroundStyle != style { cell?.backgroundStyle = style }
        // Native label colors resolve their selected contrast from backgroundStyle.
        let tint: NSColor = style == .emphasized ? .labelColor : isActive ? accent : .secondaryLabelColor
        if contentTintColor != tint { contentTintColor = tint }
    }
}
