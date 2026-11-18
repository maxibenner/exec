import XCTest
@testable import ExecRemote

final class SessionListHierarchyTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func session(_ id: String, day: Int = 10, parent: String? = nil,
                         state: String = "completed", unreadable: Bool = false) -> RemoteJSON {
        var metadata: [String: RemoteJSON] = ["title": .string(id), "activityAt": .number(Double(day) * 86_400_000 + 3_600_000)]
        if let parent {
            // Match SessionParent's camelCase wire format, not sessionID.
            metadata["parent"] = .object(["sessionId": .string(parent), "operationId": .string("operation"),
                                          "toolCallId": .string("call")])
        }
        return .object(["id": .string(id), "metadata": .object(metadata), "unreadable": .bool(unreadable),
                        "operation": .object(["state": .string(state)])])
    }

    func testChildrenStayInTheirRootDayRegardlessOfActivity() {
        let catalog = [session("new-child", day: 30, parent: "older-root"), session("older-root", day: 10),
                       session("newer-root", day: 20), session("old-child", day: 1, parent: "newer-root")]
        let groups = RemoteSessionListDay.group(catalog, calendar: calendar)
        XCTAssertEqual(groups.map { $0.rows.map(\.id) }, [["newer-root", "old-child"], ["older-root", "new-child"]])
        XCTAssertEqual(groups.map(\.id), [20, 10].map { Date(timeIntervalSince1970: Double($0) * 86_400) })
        XCTAssertEqual(groups.map { $0.rows.map(\.depth) }, [[0, 1], [0, 1]])
        // Existing callers can still request flat activity grouping.
        XCTAssertEqual(RemoteSessionDay.group(catalog, calendar: calendar).flatMap(\.conversations).compactMap { $0["id"].string },
                       ["new-child", "newer-root", "older-root", "old-child"])
    }

    func testNestedDescendantsUsePreorderAndStableCatalogSiblingOrder() {
        let catalog = [session("grandchild", day: 90, parent: "child"),
                       session("first-sibling", day: 1, parent: "root"),
                       session("child", day: 100, parent: "root"),
                       session("great-grandchild", day: 80, parent: "grandchild"),
                       session("root"), session("last-sibling", day: 50, parent: "root")]
        let rows = RemoteSessionListDay.group(catalog, calendar: calendar).flatMap(\.rows)
        XCTAssertEqual(rows.map(\.id), ["root", "first-sibling", "child", "grandchild", "great-grandchild", "last-sibling"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 2, 3, 1])
        XCTAssertEqual(rows.map(\.isSubagent), [false, true, true, true, true, true])

        let updated = catalog.map { conversation in
            session(conversation["id"].string!, day: 10, parent: conversation["metadata"]["parent"]["sessionId"].string,
                    state: "running")
        }
        XCTAssertEqual(RemoteSessionListDay.group(updated, calendar: calendar).flatMap(\.rows).map(\.id), rows.map(\.id))
    }

    func testOrphansAndUnreadableRowsRemainVisibleWithTheirDescendants() {
        let orphan = session("orphan", parent: "missing-parent", state: "running")
        let unreadable = session("main", unreadable: true)
        let child = session("descendant", day: 100, parent: "orphan")
        let rows = RemoteSessionListDay.group([child, orphan, unreadable], calendar: calendar).flatMap(\.rows)
        XCTAssertEqual(rows.map(\.conversation), [unreadable, orphan, child])
        XCTAssertEqual(rows.map(\.isSubagent), [false, true, true])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1])
        // Hierarchy projection must not lose the operation used by swipe protections.
        XCTAssertTrue(RemoteMessageSubmission.isActive(rows[1].conversation))
    }

    func testCyclesBreakDeterministicallyWithoutLosingAttachedDescendants() {
        let catalog = [session("leaf", day: 100, parent: "b"), session("a", parent: "b"),
                       session("b", parent: "c"), session("c", parent: "a"),
                       session("root", day: 20), session("self", parent: "self")]
        let groups = RemoteSessionListDay.group(catalog, calendar: calendar)
        XCTAssertEqual(groups.map { $0.rows.map(\.id) }, [["root"], ["b", "leaf", "a", "c", "self"]])
        XCTAssertEqual(groups.flatMap(\.rows).map(\.depth), [0, 0, 1, 1, 2, 0])
        let ids = groups.flatMap(\.rows).map(\.id)
        XCTAssertEqual(Set(ids), Set(catalog.compactMap { $0["id"].string }))
        XCTAssertEqual(ids.count, catalog.count)
        XCTAssertEqual(RemoteSessionListDay.group(catalog, calendar: calendar).flatMap(\.rows).map(\.id), ids)
    }

    func testRootActivityTiesUseIDWithoutSortingChildrenByID() {
        let catalog = [session("z-child", parent: "a-root"), session("b-root"),
                       session("a-child", parent: "a-root"), session("a-root")]
        let rows = RemoteSessionListDay.group(catalog, calendar: calendar).flatMap(\.rows)
        XCTAssertEqual(rows.map(\.id), ["a-root", "z-child", "a-child", "b-root"])
        XCTAssertTrue(RemoteSessionListDay.group([], calendar: calendar).isEmpty)
    }
}
