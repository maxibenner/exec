import SwiftUI

/// Deterministic layout checks, not a timing/appearance verdict. The GUI probe
/// separately samples the production List's allocated height and opacity.
@MainActor struct SidebarRowAnimationTests {
    private struct Marker: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    func childContentInsetsStayInsideItsFullWidth() throws {
        _ = NSApplication.shared
        let suite = "exec-child-content-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: FakeAgentTransport())), preferences: preferences)
        defer { library.closePresentations() }
        var child = try SessionSummary(AgentIntegrationTests.fixture(state: "completed", result: true))
        child.title = "Sub-agent title"
        let unpadded = NSHostingView(rootView: HStack(spacing: 6) {
            Text(verbatim: child.title)
            Spacer(minLength: 0)
        }.font(.caption2).fixedSize())
        let connectorWidth = NSFont.preferredFont(forTextStyle: .caption2).capHeight * 0.85
        for scheme in [ColorScheme.light, .dark] {
            // The connector replaced the old leading inset. Include its width,
            // its 6-point title gap, and the remaining 6-point trailing inset.
            // Keep measuring the production leaf, not List's combined AX label.
            let natural = NSHostingView(rootView: SessionChildRowContent(child: child, store: library)
                .fixedSize().environment(\.colorScheme, scheme))
            try expect(abs(natural.fittingSize.width - unpadded.fittingSize.width - connectorWidth - 12) < 1)
            for width in [CGFloat(180), 300] {
                let host = NSHostingView(rootView: SessionChildRowContent(child: child, store: library)
                    .frame(width: width).environment(\.colorScheme, scheme))
                try expect(abs(host.fittingSize.width - width) < 0.1)
                try expect(abs(host.fittingSize.height - 22) < 0.1)
            }
        }
    }

    func interpolatedHeightAllocatesLayoutWithoutCompressingContent() throws {
        _ = NSApplication.shared
        // Include fractional, growing and shrinking samples; zero is the initial,
        // not-yet-measured state and must use the natural height rather than hide it.
        for height in [CGFloat(0), 80, 42.5, 20, 42.5, 80] {
            var modifier = SidebarAnimatedHeight.InterpolatedHeight(height: 80)
            modifier.animatableData = height
            let content = NSView(), neighbor = NSView()
            let host = NSHostingView(rootView: VStack(spacing: 0) {
                Marker(view: content).frame(width: 180, height: 80)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(modifier)
                Marker(view: neighbor).frame(width: 180, height: 16)
            })
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            let allocated = height > 0 ? height : 80
            // NSHostingView rounds its fitting size to backing pixels.
            guard abs(host.fittingSize.height - allocated - 16) < 1 else {
                throw CheckFailure(description: "Allocated \(allocated) + neighbor 16, got fitting height \(host.fittingSize.height)")
            }
            let contentFrame = content.convert(content.bounds, to: host)
            let neighborFrame = neighbor.convert(neighbor.bounds, to: host)
            func top(_ frame: CGRect) -> CGFloat {
                host.isFlipped ? frame.minY : host.bounds.maxY - frame.maxY
            }
            // Natural content remains measurable, with the title anchored at the
            // top, while the next row follows the allocated/interpolated height.
            try expect(abs(contentFrame.height - 80) < 0.1)
            try expect(abs(top(contentFrame)) < 0.1)
            try expect(abs(top(neighborFrame) - allocated) < 1)
        }
    }
}
