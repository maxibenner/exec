import XCTest
@testable import ExecRemote

final class TranscriptSyncTests: XCTestCase {
    private let proof = String(repeating: "a", count: 64)

    private func message(_ id: String, text: String = "") -> RemoteJSON {
        .object(["id": .string(id), "role": .string("assistant"), "text": .string(text)])
    }
    private func page(_ messages: [RemoteJSON], offset: Int, total: Int, reset: Bool) -> RemoteJSON {
        .object(["snapshot": .object(["id": .string("session"), "messages": .array(messages)]),
                 "offset": .number(Double(offset)), "total": .number(Double(total)),
                 "reset": .bool(reset), "prefix": total == 0 ? .null : .string(proof)])
    }

    func testOverlapReplacesStreamingTailAndPrependingPreservesNewerState() throws {
        let first = try RemoteTranscriptSync.initial(page([message("b", text: "partial")], offset: 1, total: 2, reset: true))
        XCTAssertTrue(first.didReset)
        let updated = try first.refreshed(page([message("b", text: "done"), message("c")], offset: 1, total: 3, reset: false))
        XCTAssertFalse(updated.didReset)
        XCTAssertEqual(updated.snapshot["messages"].array.count, 2)
        XCTAssertEqual(updated.snapshot["messages"].array.first?["text"].string, "done")
        let complete = try updated.prepending(page([message("a")], offset: 0, total: 3, reset: false))
        XCTAssertEqual(complete.snapshot["messages"].array.map { $0["id"].string }, ["a", "b", "c"])
        XCTAssertFalse(complete.hasEarlier)
        XCTAssertFalse(complete.didReset)
        XCTAssertTrue(complete.refreshPath("/sync").contains("?after=c&prefix="))
    }

    func testThirtyTwoEntryPagesPreserveLargerIncrementalCatchup() throws {
        let messages = (0..<129).map { message("m\($0)") }
        let initial = try RemoteTranscriptSync.initial(page(Array(messages[64..<96]), offset: 64, total: 96, reset: true))
        XCTAssertEqual(initial.snapshot["messages"].array.count, 32)
        let catchup = try initial.refreshed(page(Array(messages[95..<129]), offset: 95, total: 129, reset: false))
        XCTAssertEqual(catchup.snapshot["messages"].array.count, 65, "Incremental responses must not be truncated to page size")
        let older = try catchup.prepending(page(Array(messages[32..<64]), offset: 32, total: 129, reset: false))
        XCTAssertTrue(older.hasEarlier)
        let complete = try older.prepending(page(Array(messages[0..<32]), offset: 0, total: 129, reset: false))
        XCTAssertFalse(complete.hasEarlier)
        XCTAssertNil(complete.earlierPath("/sync"))
        XCTAssertEqual(complete.snapshot["messages"].array, messages)
        XCTAssertEqual(complete.refreshPath("/sync"), "/sync?after=m128&prefix=" + proof)
    }

    func testGapsFailClosedAndResetsDiscardStaleHistory() throws {
        let first = try RemoteTranscriptSync.initial(page([message("a"), message("b")], offset: 0, total: 2, reset: true))
        XCTAssertThrowsError(try first.refreshed(page([message("d")], offset: 2, total: 3, reset: false)))
        XCTAssertThrowsError(try first.prepending(page([message("z")], offset: 0, total: 3, reset: false)))
        let reset = try first.refreshed(page([message("new")], offset: 4, total: 5, reset: true))
        XCTAssertEqual(reset.snapshot["messages"].array.map { $0["id"].string }, ["new"])
        XCTAssertTrue(reset.hasEarlier)
        XCTAssertTrue(reset.didReset)
    }
}
