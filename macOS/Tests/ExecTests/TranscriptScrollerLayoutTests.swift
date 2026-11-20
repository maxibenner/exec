import AppKit
import SwiftUI

@MainActor struct TranscriptScrollerLayoutTests {
    func nativeKnobFitsTheActualSplitWindowThroughResizesAndToggles() async throws {
        _ = NSApplication.shared
        let suite = "exec-scroller-window-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: FakeAgentTransport())), preferences: preferences)
        defer { library.closePresentations() }
        guard case .object(var fields) = try AgentIntegrationTests.fixture(state: "completed", result: true) else {
            throw CheckFailure(description: "Expected synthetic conversation")
        }
        fields["messages"] = .array((0..<40).map { index in
            .object(["id": .string(UUID().uuidString), "role": .string("assistant"),
                     "text": .string("Synthetic transcript row \(index)\nSecond line."), "status": .string("complete")])
        })
        try library.current.apply(AgentJSON.object(fields).decoded(AgentSnapshot.self))
        let state = TranscriptState()
        let controller = NSHostingController(rootView: ChatWindowLayout(initiallyShowsSidebar: true) {
            Text("Synthetic sidebar")
        } detail: {
            ConversationView(library: library, conversation: library.current, presentation: state, focused: .constant(false))
        })
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.setContentSize(NSSize(width: 980, height: 600))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        try await Task.sleep(for: .milliseconds(200))
        guard let content = window.contentView,
              let split = views(content).compactMap({ $0 as? NSSplitView }).first,
              let splitController = split.delegate as? NSSplitViewController,
              let transcript = views(content).compactMap({ $0 as? TranscriptScrollView }).first else {
            throw CheckFailure(description: "Actual transcript/split window did not mount")
        }
        transcript.autohidesScrollers = false
        for style in [NSScroller.Style.overlay, .legacy] {
            transcript.scrollerStyle = style
            for width: CGFloat in [980, 720, 721, 800] {
                window.setContentSize(NSSize(width: width, height: 600))
                for sidebarWidth: CGFloat in [200, 240, 320] {
                    split.setPosition(sidebarWidth, ofDividerAt: 0)
                    try await Task.sleep(for: .milliseconds(50))
                    content.layoutSubtreeIfNeeded()
                    transcript.tile()
                    transcript.refresh()
                    guard let scroller = transcript.verticalScroller else { throw CheckFailure(description: "Missing native scroller") }
                    let knob = scroller.rect(for: .knob)
                    let visible = scroller.visibleRect
                    let frame = transcript.convert(transcript.bounds, to: content)
                    guard !knob.isEmpty, visible.contains(knob), content.bounds.maxX >= frame.maxX - 0.1 else {
                        throw CheckFailure(description: "Clipped scroller style=\(style.rawValue), window=\(width), sidebar=\(sidebarWidth): knob=\(knob), visible=\(visible), transcript=\(frame), window=\(content.bounds)")
                    }
                }
            }
            // The native toggle must not leave an oversized detail surface behind.
            for _ in 0..<2 {
                splitController.toggleSidebar(nil)
                try await Task.sleep(for: .milliseconds(350))
                content.layoutSubtreeIfNeeded()
                let scroller = transcript.verticalScroller!
                try expect(scroller.visibleRect.contains(scroller.rect(for: .knob)))
            }
        }
    }
}
