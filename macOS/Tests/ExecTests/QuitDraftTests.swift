import AppKit

@MainActor struct QuitDraftTests {
    func idleAndDetachedDraftsRequireExplicitLossConfirmation() async throws {
        for detached in [false, true] {
            for content in ["text", "image", "file"] {
                let suite = "exec-quit-draft-\(UUID())"
                let preferences = UserDefaults(suiteName: suite)!
                defer { preferences.removePersistentDomain(forName: suite) }
                let transport = FakeAgentTransport()
                let library = ChatLibrary(provider: AgentAccounts(api: AgentAPI(transport: transport)), preferences: preferences)
                defer { library.closePresentations() }
                let draft = library.current
                if content == "text" { draft.draft = "Do not discard silently" }
                if content == "image" {
                    draft.draftImages = [ImageAttachment(name: "draft.png", mediaType: "image/png", data: Data([1]))]
                }
                if content == "file" { draft.draftFiles = [FileAttachment(name: "draft.txt", data: Data([2]))] }
                if detached {
                    try draft.apply(AgentIntegrationTests.fixture(state: "completed", result: true).decoded(AgentSnapshot.self))
                    var presented = false
                    library.detachSession(AgentIntegrationTests.conversationID) { presented = $0 === draft }
                    try expect(presented && library.current !== draft && !library.current.hasUnsentDraft)
                }
                try expect(library.hasUnsentDrafts && !library.hasRunningOperations && !library.hasUnsavedChanges)
                let delegate = AppDelegate()
                delegate.store = library
                var confirmations = 0, shutdowns = 0
                var replies: [Bool] = []
                var title = "", warning = ""
                delegate.confirmQuit = { alert, _ in
                    confirmations += 1
                    title = alert.messageText
                    warning = alert.informativeText
                    return confirmations == 1 ? .alertSecondButtonReturn : .alertFirstButtonReturn
                }
                delegate.shutdownBackend = { shutdowns += 1 }
                delegate.replyToTermination = { _, value in replies.append(value) }
                try expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
                try await SessionLifecycleTests.wait("cancel idle draft quit") { replies == [false] }
                try expect(confirmations == 1 && shutdowns == 0 && draft.hasUnsentDraft)
                try expect(title == "Quit Exec?")
                try expect(warning == "Unsent text and attachments in all conversations will be discarded. Saved conversations will be kept.")
                try expect(draft.draft == (content == "text" ? "Do not discard silently" : ""))
                try expect(draft.draftImages.count == (content == "image" ? 1 : 0))
                try expect(draft.draftFiles.count == (content == "file" ? 1 : 0))
                try expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
                try await SessionLifecycleTests.wait("confirm idle draft quit") { replies == [false, true] }
                try expect(confirmations == 2 && shutdowns == 1)
                let requests = await transport.requests
                try expect(requests.isEmpty)
            }
        }
    }
}
