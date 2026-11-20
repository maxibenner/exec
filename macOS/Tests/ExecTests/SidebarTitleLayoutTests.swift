import SwiftUI

@MainActor struct SidebarTitleLayoutTests {
    func singleAndWrappedTitlesUseTheSamePadding() throws {
        _ = NSApplication.shared
        let suite = "exec-sidebar-title-layout-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: FakeAgentTransport())), preferences: preferences)
        defer { library.closePresentations() }
        var session = try SessionSummary(AgentIntegrationTests.fixture(state: "completed", result: true))
        let width: CGFloat = 240
        var previousTextHeight: CGFloat = 0
        for title in ["Single-line title", "A two-line\nsession title"] {
            session.title = title
            let row = NSHostingView(rootView: SessionRow(session: session, store: library, rename: {}, delete: {})
                .frame(width: width).fixedSize(horizontal: false, vertical: true))
            // Match the title's available width: 16-point status slot + 8-point gap.
            let text = NSHostingView(rootView: Text(verbatim: title).font(.body.weight(.regular)).lineLimit(2)
                .frame(width: width - 24).fixedSize(horizontal: false, vertical: true))
            let textHeight = text.fittingSize.height
            try expect(textHeight > previousTextHeight)
            previousTextHeight = textHeight
            // Both line counts get 5 points above and 4 below. The status slot
            // must not impose its own minimum height on the single-line case.
            try expect(abs(row.fittingSize.height - textHeight - 9) < 1)
        }
    }
}
