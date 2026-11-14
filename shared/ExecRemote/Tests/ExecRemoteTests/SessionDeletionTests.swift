import XCTest
@testable import ExecRemote

final class SessionDeletionTests: XCTestCase {
    private func session(_ id: String, title: String = "Saved session") -> RemoteJSON {
        .object(["id": .string(id), "metadata": .object(["title": .string(title)])])
    }
    func testPendingDeletionStaysHiddenAcrossStaleRefreshes() {
        var deletions = RemoteSessionDeletions()
        let rows = [session("a"), session("b")]
        deletions.begin(rows[0])
        XCTAssertEqual(deletions.project(rows), [rows[1]])
        XCTAssertEqual(deletions.reconcile(rows), [rows[1]])
        // A list can omit the row before the DELETE acknowledgement arrives.
        XCTAssertEqual(deletions.reconcile([rows[1]]), [rows[1]])
        XCTAssertEqual(deletions.reconcile(rows), [rows[1]])
        XCTAssertEqual(deletions.pendingIDs, ["a"])
    }
    func testFailureRestoresLatestMetadataAndDoesNotAffectOtherSessions() {
        var deletions = RemoteSessionDeletions()
        deletions.begin(session("a"))
        let updated = session("a", title: "Updated title")
        _ = deletions.reconcile([updated, session("b")])
        XCTAssertEqual(deletions.fail("a"), updated)
        XCTAssertEqual(deletions.project([updated, session("b")]), [updated, session("b")])
        XCTAssertTrue(deletions.pendingIDs.isEmpty)
    }
    func testAcceptedDeletionCannotBeRestoredByRefreshFailureOrStaleList() {
        var deletions = RemoteSessionDeletions()
        let rows = [session("a"), session("b")]
        deletions.begin(rows[0]); deletions.accept("a")
        XCTAssertNil(deletions.fail("a"))
        XCTAssertEqual(deletions.project(rows), [rows[1]])
        XCTAssertEqual(deletions.reconcile(rows), [rows[1]])
        XCTAssertEqual(deletions.reconcile([rows[1]]), [rows[1]])
        XCTAssertTrue(deletions.pendingIDs.isEmpty)
        deletions = RemoteSessionDeletions() // Host change drops local state.
        XCTAssertEqual(deletions.project(rows), rows)
    }
}
