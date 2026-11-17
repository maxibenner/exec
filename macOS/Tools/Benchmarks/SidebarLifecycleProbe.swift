import AppKit
import SwiftUI

private struct LifecycleProbeView: View {
    let library: ChatLibrary
    let windows: SessionWindows
    var body: some View {
        ChatWindowLayout(initiallyShowsSidebar: true) {
            SessionSidebar(store: library, open: { windows.openSession($0) }, delete: { windows.requestSessionDeletion($0.id) })
        } detail: {
            ChatView(store: library, windows: windows)
        }
        .environment(windows)
    }
}

private final class LifecycleProbeWindow: NSWindow {
    var trace: (String) -> Void = { _ in }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        trace("responder=\(responder.map { String(describing: type(of: $0)) } ?? "nil") accepted=\(result)")
        return result
    }
}

@main struct SidebarLifecycleProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("PROBE ERROR \(error)"); exit(1) }
        }
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    @MainActor static func run() async throws {
        let flags = Set(CommandLine.arguments.dropFirst())
        guard flags.isSubset(of: ["--completed", "--catalog-first", "--checks"]) else {
            throw ExecError("Usage: probe-sidebar-lifecycle.sh [--completed] [--catalog-first] | --checks")
        }
        if flags.contains("--checks") {
            let tests = SessionLifecycleTests()
            let checks: [(String, @MainActor () async throws -> Void)] = [
                ("cleanup ordering", tests.cleanupOrdersNeverPublishConnectionWarnings),
                ("drafts and real errors", tests.cleanupPreservesDraftsAndRealFailures),
                ("remote cancellation", tests.cleanupSettlesRemoteCancellationWithoutHidingRealErrors),
                ("stale catalogs", tests.staleCatalogsAndObserverGenerationsCannotRemoveNewResidents),
                ("creation and registration", tests.creationAndRegistrationSurviveOlderAbsence),
                ("cold parent fallback", tests.cleanupLoadsEvictedParentAndKeepsSafeFallback),
                ("navigation and detached ownership", tests.cleanupDuringNavigationRespectsParentWindowOwnership),
                ("native composer focus", tests.nativeComposerFocusFollowsRequestsAndCleanup)
            ]
            for (name, check) in checks { try await check(); print("PASS \(name)") }
            return
        }
        let fixture = try LifecycleFixture(running: !flags.contains("--completed"))
        try await fixture.start()
        defer { fixture.close() }
        let library = fixture.library
        let windows = SessionWindows(library: library)
        let start = Date()
        func trace(_ event: String) {
            print(String(format: "%.3f", Date().timeIntervalSince(start)), event,
                  "active=\(library.currentSessionID?.uuidString.prefix(8) ?? "nil") navigating=\(library.navigating) request=\(windows.composerFocusRequest)")
        }
        let window = LifecycleProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.trace = trace
        window.title = "Exec isolated lifecycle probe"
        let host = NSHostingView(rootView: LifecycleProbeView(library: library, windows: windows))
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(250))

        // Exercise production navigation and native editor ownership. Fabricated
        // NSEvents do not reliably invoke SwiftUI gestures; physical clicks remain
        // a manual check rather than a misleading synthetic pass/fail assertion.
        func select(_ id: UUID) {
            trace("navigation request \(id.uuidString.prefix(8))")
            windows.openSession(id)
        }
        var failures = 0
        func sample(_ label: String, expected: UUID) async {
            // A unique draft proves the editor belongs to the selected composer,
            // rather than merely checking that some text responder exists.
            do {
                try await SessionLifecycleTests.wait(label) {
                    host.layoutSubtreeIfNeeded()
                    guard let editor = window.firstResponder as? NSTextView else { return false }
                    return library.currentSessionID == expected && editor.string == library.current.draft &&
                        editor.isEditable && editor.window === window
                }
                trace("RESULT \(label) PASS")
            } catch {
                failures += 1
                trace("RESULT \(label) FAIL: \(error)")
            }
        }
        library.current.draft = "parent composer"
        select(fixture.childID)
        await library.waitForNavigation()
        if library.currentSessionID == fixture.childID { library.current.draft = "child composer" }
        await sample("cold child", expected: fixture.childID)
        // Take focus away just as selecting transcript text or another control does.
        _ = window.makeFirstResponder(host)
        select(fixture.childID)
        await sample("selected child", expected: fixture.childID)
        select(fixture.parentID)
        await sample("resident parent", expected: fixture.parentID)
        select(fixture.childID)
        await sample("resident child", expected: fixture.childID)
        select(fixture.otherID)
        select(fixture.childID)
        await sample("rapid last selection", expected: fixture.childID)
        guard library.currentSessionID == fixture.childID else { throw ExecError("Child navigation failed") }
        library.current.draft = ""
        let child = library.current
        let catalogFirst = flags.contains("--catalog-first")
        try await fixture.removeChild(failSync: !catalogFirst)
        if catalogFirst { try await library.current.didCheckpoint?() }
        var warningSamples = 0
        try await SessionLifecycleTests.wait("automatic child cleanup") {
            if child.error != nil { warningSamples += 1 }
            return child.deletedRemotely
        }
        trace("\(catalogFirst ? "catalog-first" : "poll-first") warningSamples=\(warningSamples) deleted=\(child.deletedRemotely)")
        // Do not force a catalog sweep here: that would hide a broken observer path.
        await sample("automatic parent fallback", expected: fixture.parentID)
        print("SUMMARY focusFailures=\(failures) warningSamples=\(warningSamples)")
        if failures > 0 || warningSamples > 0 { throw ExecError("Lifecycle probe checks failed") }
    }
}
