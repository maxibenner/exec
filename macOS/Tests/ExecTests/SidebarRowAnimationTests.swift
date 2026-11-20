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
        let connectorWidth = NSFont.preferredFont(forTextStyle: .caption2).capHeight * 0.85
        for showsStatus in [false, true] {
            let snapshot = try AgentIntegrationTests.fixture(
                state: showsStatus ? "awaiting_approval" : "completed", result: !showsStatus)
                .decoded(AgentSnapshot.self)
            try library.current.apply(snapshot)
            try expect(library.needsApproval(snapshot.id) == showsStatus)
            for title in ["Sub-agent title", "A long child title that must truncate rather than wrap in a narrow sidebar"] {
                var child = SessionSummary(snapshot: snapshot)
                child.title = title
                // Measure text alone: a reference HStack with a Spacer introduces
                // its own gap. fixedSize here checks ideal, untruncated content.
                let text = NSHostingView(rootView: Text(verbatim: title).font(.caption2).fixedSize())
                for scheme in [ColorScheme.light, .dark] {
                    let natural = NSHostingView(rootView: SessionChildRowContent(child: child, store: library)
                        .fixedSize().environment(\.colorScheme, scheme))
                    // Connector + inner gap + spacer gap. An empty status Group
                    // has no layout, even with .frame(width: 16); a visible status
                    // adds that frame and one more gap. No leading gutter here.
                    let extraWidth = connectorWidth + 12 + (showsStatus ? 22 : 0)
                    guard abs(natural.fittingSize.width - text.fittingSize.width - extraWidth) < 1 else {
                        throw CheckFailure(description: "Child width=\(natural.fittingSize.width), text=\(text.fittingSize.width), expected extra=\(extraWidth), status=\(showsStatus)")
                    }
                    for width in [CGFloat(180), 300] {
                        let content = NSView()
                        let host = NSHostingView(rootView: SessionChildRowContent(child: child, store: library)
                            .background(Marker(view: content))
                            .frame(width: width).environment(\.colorScheme, scheme))
                        host.frame.size = host.fittingSize
                        host.layoutSubtreeIfNeeded()
                        try expect(abs(host.fittingSize.width - width) < 0.1)
                        try expect(abs(host.fittingSize.height - 22) < 0.1)
                        // Measure the row inside the imposed frame, not just the
                        // wrapper: content/status must retain the full hit width.
                        let frame = content.convert(content.bounds, to: host)
                        try expect(abs(frame.minX) < 0.1 && abs(frame.width - width) < 0.1)
                        try expect(abs(frame.height - 22) < 0.1)
                    }
                }
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
