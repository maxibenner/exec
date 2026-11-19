import XCTest
import ExecRemote
@testable import ExecRemoteStore

@MainActor final class ConversationPresentationTests: XCTestCase {
    private func conversation(_ id: String, title: String) -> RemoteJSON {
        .object(["id": .string(id), "metadata": .object(["title": .string(title)]), "messages": .array([])])
    }

    private func makeStore(_ transport: FakeTransport) throws -> RemoteStore {
        let invitation = try RemoteJSON.object([
            "version": .number(1), "relay": .string("wss://example.invalid"),
            "route": .string(String(repeating: "a", count: 64)),
            "hostKey": .string(Data(repeating: 0, count: 32).base64EncodedString()),
            "expires": .number(0), "localDevelopment": .bool(false)
        ]).decoded(PairingInvitation.self)
        let host = PairedHost(invitation: invitation, deviceName: "Title fixture")
        return RemoteStore(client: transport, loadHost: { host }, saveHost: { _ in }, forgetHost: {})
    }

    private func waitForRead(_ transport: FakeTransport) async throws {
        for _ in 0..<10_000 {
            if await transport.waitingForRequest { return }
            await Task.yield()
        }
        XCTFail("Conversation read did not start")
        throw RemoteFailure("Test synchronization failed.")
    }

    func testMatchingTitlesUpdateWithoutAcceptingAnotherSessionsContent() {
        let catalog = [conversation("other", title: "Other catalog"), conversation("session", title: "Catalog title")]
        var presentation = ConversationPresentation(conversationID: "session", catalog: catalog,
                                                    snapshot: conversation("other", title: "Other snapshot"))
        XCTAssertEqual(presentation.title, "Catalog title")
        XCTAssertEqual(presentation.snapshot, .null)

        let snapshot = conversation("session", title: "Updated title")
        presentation.update(snapshot)
        presentation.update(.null)
        presentation.update(conversation("other", title: "Do not display this"))
        XCTAssertEqual(presentation.conversationID, "session")
        XCTAssertEqual(presentation.title, "Updated title")
        XCTAssertEqual(presentation.snapshot, snapshot, "Outgoing content must stay paired with its route ID")

        presentation.update(.object(["id": .string("session"), "messages": .array([])]))
        XCTAssertEqual(presentation.title, "Updated title", "Missing metadata must not reset the last correct title")
        presentation.update(conversation("session", title: "Renamed again"))
        XCTAssertEqual(presentation.title, "Renamed again")
    }

    func testChildLegacyAndNewSessionsUseOnlyTheirOwnFallbacks() {
        let parent = conversation("parent", title: "Parent title")
        let child: RemoteJSON = .object([
            "id": .string("child"), "metadata": .object([
                "title": .string("Child title"), "parent": .object(["sessionId": .string("parent")])])
        ])
        let legacy: RemoteJSON = .object(["id": .string("legacy"), "title": .string("Legacy title")])
        let catalog = [parent, child, legacy]
        let childPresentation = ConversationPresentation(conversationID: "child", catalog: catalog, snapshot: parent)
        XCTAssertEqual(childPresentation.title, "Child title")
        XCTAssertEqual(childPresentation.snapshot, .null)
        var legacyPresentation = ConversationPresentation(conversationID: "legacy", catalog: catalog, snapshot: .null)
        XCTAssertEqual(legacyPresentation.title, "Legacy title")
        legacyPresentation.update(.object(["id": .string("legacy"), "title": .string("Legacy snapshot")]))
        XCTAssertEqual(legacyPresentation.title, "Legacy snapshot")

        var created = ConversationPresentation(conversationID: "created", catalog: catalog, snapshot: parent)
        XCTAssertEqual(created.title, "Chat")
        created.update(conversation("created", title: "New Session"))
        XCTAssertEqual(created.title, "New Session")
        XCTAssertEqual(created.snapshot["id"].string, "created")
    }

    func testDelayedOpenUsesCatalogImmediatelyAndRetainsSnapshotTitleAfterPop() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.setSessions([conversation("session", title: "Already on the list")])
        await transport.setConversation(conversation("session", title: "Authoritative snapshot title"))
        await store.connect()
        await transport.holdNextRequest("GET", "/v1/conversations/session/sync")
        let opening = store.open("session")
        var presentation = ConversationPresentation(conversationID: "session", catalog: store.conversations,
                                                    snapshot: store.displaySnapshot)
        XCTAssertEqual(store.snapshot, .null)
        XCTAssertEqual(presentation.title, "Already on the list", "No read or observation callback is needed for the first title")
        try await waitForRead(transport)
        await transport.releaseRequest(); await opening.value
        presentation.update(store.displaySnapshot)
        XCTAssertEqual(presentation.title, "Authoritative snapshot title")

        store.selected = nil
        XCTAssertEqual(store.snapshot, .null)
        presentation.update(store.displaySnapshot)
        XCTAssertEqual(presentation.title, "Authoritative snapshot title")
        XCTAssertEqual(presentation.snapshot["id"].string, "session")
    }

    func testLateReadAndNextSessionCannotReplaceOutgoingTitleAndReopeningUsesCache() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.setSessions([conversation("session", title: "First catalog"), conversation("other", title: "Second catalog")])
        await transport.setConversation(conversation("session", title: "First snapshot"))
        await transport.setSnapshot(conversation("other", title: "Second snapshot"), for: "other")
        await store.connect()
        await transport.holdNextRequest("GET", "/v1/conversations/session/sync")
        let firstRead = store.open("session")
        var outgoing = ConversationPresentation(conversationID: "session", catalog: store.conversations, snapshot: store.displaySnapshot)
        try await waitForRead(transport)
        store.selected = nil
        outgoing.update(store.displaySnapshot)
        await store.open("other").value
        let other = ConversationPresentation(conversationID: "other", catalog: store.conversations, snapshot: store.displaySnapshot)
        outgoing.update(store.displaySnapshot)
        XCTAssertEqual(outgoing.title, "First catalog")
        XCTAssertEqual(outgoing.snapshot, .null)
        XCTAssertEqual(other.title, "Second snapshot")

        await transport.releaseRequest(); await firstRead.value
        XCTAssertEqual(store.selected, "other")
        XCTAssertEqual(store.snapshot["id"].string, "other")
        outgoing.update(store.displaySnapshot)
        XCTAssertEqual(outgoing.title, "First catalog")
        let reopening = store.open("session")
        let reopened = ConversationPresentation(conversationID: "session", catalog: store.conversations, snapshot: store.displaySnapshot)
        XCTAssertEqual(reopened.title, "First snapshot", "The cached matching snapshot takes precedence over the older catalog")
        XCTAssertEqual(reopened.snapshot["id"].string, "session")
        await reopening.value
    }

    func testDeletingSelectionKeepsOutgoingTitleWithoutLeakingIntoAFutureDestination() async throws {
        let transport = FakeTransport(), store = try makeStore(transport)
        await transport.setSessions([conversation("session", title: "Catalog title")])
        await transport.setConversation(conversation("session", title: "Deleted session title"))
        await store.connect(); await store.open("session").value
        var outgoing = ConversationPresentation(conversationID: "session", catalog: store.conversations, snapshot: store.displaySnapshot)
        await store.deleteConversation("session")
        XCTAssertNil(store.selected)
        XCTAssertEqual(store.snapshot, .null)
        XCTAssertTrue(store.conversations.isEmpty)
        outgoing.update(store.displaySnapshot)
        XCTAssertEqual(outgoing.title, "Deleted session title")

        await store.forget()
        let future = ConversationPresentation(conversationID: "session", catalog: store.conversations, snapshot: store.displaySnapshot)
        XCTAssertEqual(future.title, "Chat")
        XCTAssertEqual(future.snapshot, .null)
    }
}
