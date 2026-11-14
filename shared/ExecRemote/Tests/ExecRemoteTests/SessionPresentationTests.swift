import XCTest
@testable import ExecRemote

final class SessionPresentationTests: XCTestCase {
    private func snapshot(_ id: String, state: String = "completed", text: String = "Saved transcript") -> RemoteJSON {
        .object(["id": .string(id), "messages": .array([.object(["text": .string(text)])]),
                 "operation": .object(["id": .string("operation-1"), "state": .string(state)])])
    }

    func testThreeViewedSessionsAreCachedAndRefreshDoesNotChangeRecency() {
        var cache = RecentConversationCache()
        for id in ["a", "b", "c"] {
            XCTAssertNil(cache.visit(id))
            cache.update(snapshot(id))
        }
        XCTAssertEqual(cache.visit("a"), snapshot("a"))
        // A background refresh of b must not count as viewing it.
        cache.update(snapshot("b", text: "Refreshed"))
        XCTAssertNil(cache.visit("d"))
        cache.update(snapshot("d"))
        XCTAssertEqual(cache.visit("a"), snapshot("a"))
        XCTAssertEqual(cache.visit("c"), snapshot("c"))
        XCTAssertNil(cache.visit("b"))
    }

    func testRefreshKeepsLastSeenSnapshotAndDoesNotResurrectEvictions() {
        var cache = RecentConversationCache()
        _ = cache.visit("a"); cache.update(snapshot("a"))
        // Visiting doesn't clear the previous contents while a read is in flight,
        // nor when that read fails and supplies no replacement snapshot.
        XCTAssertEqual(cache.visit("a"), snapshot("a"))
        XCTAssertEqual(cache.visit("a"), snapshot("a"))
        cache.update(snapshot("a", text: "New content"))
        XCTAssertEqual(cache.visit("a"), snapshot("a", text: "New content"))
        cache.remove("a")
        cache.update(snapshot("a"))
        XCTAssertNil(cache.visit("a"))
        cache.update(snapshot("a"))
        cache.retain([])
        XCTAssertNil(cache.visit("a"))
        cache = RecentConversationCache()
        XCTAssertNil(cache.visit("a"))
    }

    func testSendSteersOnlyTheObservedActiveOperation() throws {
        let idle = try XCTUnwrap(RemoteMessageSubmission(conversationID: "a", snapshot: snapshot("a"), text: "Hello"))
        XCTAssertEqual(idle.path, "/v1/conversations/a/turns")
        XCTAssertEqual(idle.body["text"].string, "Hello")
        for state in ["running", "awaiting_approval", "cancelling"] {
            let active = snapshot("a", state: state)
            let queued = try XCTUnwrap(RemoteMessageSubmission(conversationID: "a", snapshot: active, text: "Next message"))
            XCTAssertEqual(queued.path, "/v1/conversations/a/steer")
            XCTAssertEqual(queued.body["operationID"].string, "operation-1")
            XCTAssertTrue(RemoteMessageSubmission.showsStop(snapshot: active, draft: " \n"))
            XCTAssertFalse(RemoteMessageSubmission.showsStop(snapshot: active, draft: "Next message"))
        }
        XCTAssertNil(RemoteMessageSubmission(conversationID: "b", snapshot: snapshot("a"), text: "Hello"))
        XCTAssertNil(RemoteMessageSubmission(conversationID: "a", snapshot: snapshot("a"), text: " \n"))
        XCTAssertFalse(RemoteMessageSubmission.showsStop(snapshot: snapshot("a"), draft: ""))
        let missingOperationID: RemoteJSON = .object(["id": .string("a"), "operation": .object(["state": .string("running")])])
        XCTAssertNil(RemoteMessageSubmission(conversationID: "a", snapshot: missingOperationID, text: "Hello"))
    }

    func testQueuedMessagesRemainVisibleWithStableIdentity() {
        let message: RemoteJSON = .object(["id": .string("queued-message"), "role": .string("user"), "text": .string("Next question")])
        let pending = RemoteTranscriptRow.project(.object(["pendingInput": .array([message])]))
        let injected = RemoteTranscriptRow.project(.object(["messages": .array([message])]))
        XCTAssertEqual(pending, injected)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(RemoteTranscriptRow.project(.object(["messages": .array([message]), "pendingInput": .array([message])])).count, 1)
    }

    func testSessionsGroupByLocalDayAndSortNewestFirstAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-09T07:30:00Z"))
        func session(_ id: String, hoursAgo: Double) -> RemoteJSON {
            .object(["id": .string(id), "metadata": .object(["activityAt": .number(now.addingTimeInterval(-hoursAgo * 3600).timeIntervalSince1970 * 1000)])])
        }
        let days = RemoteSessionDay.group([session("old", hoursAgo: 49), session("yesterday-early", hoursAgo: 22), session("today", hoursAgo: 0), session("yesterday-late", hoursAgo: 2)], calendar: calendar)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[0].title(now: now, calendar: calendar), "Today")
        XCTAssertEqual(days[1].title(now: now, calendar: calendar), "Yesterday")
        XCTAssertEqual(days[1].conversations.map { $0["id"].string }, ["yesterday-late", "yesterday-early"])
        XCTAssertEqual(days[2].title(now: now, calendar: calendar, locale: Locale(identifier: "en_US")), "March 6")
    }
}
