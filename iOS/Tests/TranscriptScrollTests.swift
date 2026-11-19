import XCTest
import ExecRemote
@testable import ExecRemoteStore

final class TranscriptScrollTests: XCTestCase {
    private func message(_ id: String, _ role: String = "user", text: String = "Fixture") -> RemoteJSON {
        .object(["id": .string(id), "role": .string(role), "text": .string(text)])
    }
    private func snapshot(_ messages: [RemoteJSON], active: String? = nil) -> RemoteJSON {
        .object(["id": .string("fixture"), "messages": .array(messages), "activeToolCallID": .optional(active)])
    }
    private func rows(_ messages: [RemoteJSON]) -> [RemoteTranscriptRow] { RemoteTranscriptRow.project(snapshot(messages)) }

    func testAdjacentToolsShareOneItemWithoutLosingCallIdentityOrActivity() {
        let calls: RemoteJSON = .object(["id": .string("calls"), "role": .string("assistant"), "calls": .array([
            .object(["id": .string("a"), "name": .string("shell")]),
            .object(["id": .string("b"), "name": .string("shell")])])])
        let result: RemoteJSON = .object(["id": .string("result"), "role": .string("tool"), "callID": .string("a"),
                                          "outcome": .string("completed"), "text": .string("Done")])
        let before = TranscriptItem.project(snapshot([message("user"), calls, result], active: "b"))
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(before[1].rows.map(\.id), ["tool:calls:b", "tool:calls:a"])
        XCTAssertTrue(before[1].rows[0].isRunning)
        XCTAssertFalse(before[1].rows[1].isRunning)
        let terminal: RemoteJSON = .object(["id": .string("result-b"), "role": .string("tool"), "callID": .string("b"),
                                            "outcome": .string("completed"), "text": .string("Finished")])
        let after = TranscriptItem.project(snapshot([message("user"), calls, result, terminal, message("answer", "assistant")]))
        XCTAssertEqual(after.count, 3)
        XCTAssertEqual(Set(before[1].rows.map(\.id)), Set(after[1].rows.map(\.id)))
        XCTAssertFalse(after[1].rows[1].isRunning)
    }

    func testInitialAndPrependedHistoryAreNotNewSends() {
        var state = TranscriptScrollState()
        let old = [message("question"), message("answer", "assistant")]
        XCTAssertFalse(state.update(rows: rows(old)))
        XCTAssertEqual(state.intent, .latest)
        state.readerScrolled(towardLatest: false, atBottom: false)
        XCTAssertFalse(state.update(rows: rows([message("older")] + old)))
        XCTAssertEqual(state.intent, .reading)
        // A newly mounted cached session starts at latest without a send animation.
        var cached = TranscriptScrollState()
        XCTAssertFalse(cached.update(rows: rows(old + [message("other-device")])) )
        XCTAssertEqual(cached.intent, .latest)
    }

    func testSendAnchorsEvenWhenFirstResponseArrivesInSameUpdate() {
        var state = TranscriptScrollState()
        XCTAssertFalse(state.update(rows: []))
        let turn = [message("local-send"), message("response", "assistant", text: "Already answering")]
        XCTAssertTrue(state.update(rows: rows(turn)))
        XCTAssertEqual(state.intent, .turn("local-send"))
        XCTAssertEqual(state.reservedTurnID, "local-send")
        XCTAssertFalse(state.update(rows: rows([turn[0], message("response", "assistant", text: "Longer response")])) )
        XCTAssertEqual(state.intent, .turn("local-send"))
        // The optimistic ID remains stable on acknowledgement, not a second send.
        XCTAssertFalse(state.update(rows: rows(turn)))
    }

    func testOnlyAnExplicitDownwardScrollToBottomResumesFollowing() {
        var state = TranscriptScrollState()
        _ = state.update(rows: [])
        _ = state.update(rows: rows([message("local-send")]))
        state.readerScrolled(towardLatest: false, atBottom: true)
        XCTAssertEqual(state.intent, .reading)
        XCTAssertEqual(state.reservedTurnID, "local-send")
        state.readerScrolled(towardLatest: true, atBottom: false)
        XCTAssertEqual(state.intent, .reading)
        _ = state.update(rows: rows([message("local-send"), message("response", "assistant")]))
        XCTAssertEqual(state.intent, .reading)
        state.readerScrolled(towardLatest: true, atBottom: true)
        XCTAssertEqual(state.intent, .latest)
        XCTAssertNil(state.reservedTurnID)
    }

    func testRemoteUpdatesRespectReadingButExplicitLocalSendsCanFollow() {
        var state = TranscriptScrollState()
        _ = state.update(rows: rows([message("old")]))
        state.readerScrolled(towardLatest: false, atBottom: false)
        XCTAssertFalse(state.update(rows: rows([message("old"), message("remote")])))
        XCTAssertEqual(state.intent, .reading)
        XCTAssertTrue(state.update(rows: rows([message("old"), message("remote"), message("local-next")])))
        XCTAssertEqual(state.intent, .turn("local-next"))
        // A rejected local send removes its pin and reservation without replaying it.
        _ = state.update(rows: rows([message("old"), message("remote")]))
        XCTAssertNil(state.reservedTurnID)
        XCTAssertEqual(state.intent, .latest)
    }

    func testRestorationAdoptsHiddenUpdatesWithoutReplayingASend() {
        var state = TranscriptScrollState()
        _ = state.update(rows: rows([message("old")]))
        state.readerScrolled(towardLatest: false, atBottom: false)
        let cached = rows([message("old"), message("local-delivered-while-hidden")])
        state.restoreRows(cached)
        XCTAssertEqual(state.intent, .reading)
        XCTAssertFalse(state.update(rows: cached))
        XCTAssertTrue(state.update(rows: cached + rows([message("local-next")])) )
        XCTAssertEqual(state.intent, .turn("local-next"))
    }

    func testRestorationDropsATurnRemovedByHistoryReset() {
        var state = TranscriptScrollState()
        _ = state.update(rows: [])
        _ = state.update(rows: rows([message("local-send")]))
        let reset = rows([message("summary", "assistant")])
        state.restoreRows(reset)
        XCTAssertEqual(state.intent, .latest)
        XCTAssertNil(state.reservedTurnID)
        XCTAssertFalse(state.update(rows: reset))
    }

    @MainActor func testViewStateFollowsTheThreeSessionCacheAndRejectsEvictedWrites() throws {
        let store = RemoteStore(client: FakeTransport(), loadHost: { nil }, saveHost: { _ in }, forgetHost: {})
        for id in ["a", "b", "c"] {
            store.selected = id
            var value = try XCTUnwrap(store.transcriptViewState(for: id))
            value.anchor = .init(rowID: "message-\(id)", offset: 17)
            value.expansion["tool-\(id)"] = true
            store.saveTranscriptViewState(value, for: id)
        }
        let stale = try XCTUnwrap(store.transcriptViewState(for: "b"))
        store.selected = "a"
        store.selected = "d" // b is now evicted, just like its transcript history.
        XCTAssertNil(store.transcriptViewState(for: "b"))
        store.saveTranscriptViewState(stale, for: "b")
        XCTAssertNil(store.transcriptViewState(for: "b"))
        XCTAssertEqual(store.transcriptViewState(for: "a")?.anchor, TranscriptViewportAnchor(rowID: "message-a", offset: 17))
        XCTAssertEqual(store.transcriptViewState(for: "a")?.expansion["tool-a"], true)
    }

    @MainActor func testForgettingClearsViewStateAndRejectsThePreviousHostWriter() async throws {
        let store = RemoteStore(client: FakeTransport(), loadHost: { nil }, saveHost: { _ in }, forgetHost: {})
        store.selected = "same-id"
        var old = try XCTUnwrap(store.transcriptViewState(for: "same-id"))
        old.anchor = .init(rowID: "private-old-message", offset: 20)
        store.saveTranscriptViewState(old, for: "same-id")
        await store.forget()
        store.selected = "same-id"
        let replacement = try XCTUnwrap(store.transcriptViewState(for: "same-id"))
        XCTAssertNotEqual(replacement.generation, old.generation)
        store.saveTranscriptViewState(old, for: "same-id")
        XCTAssertNil(store.transcriptViewState(for: "same-id")?.anchor)
    }

    func testResponseConsumesReservationAndKeyboardUsesUnobscuredViewport() {
        let target = TranscriptScrollGeometry.turnOffset(rowTop: 1_000, topInset: 100)
        XCTAssertEqual(target, 892)
        let reserved = TranscriptScrollGeometry.reservation(turnOffset: target, naturalHeight: 1_100,
                                                             viewportHeight: 800, bottomInset: 100)
        XCTAssertEqual(reserved, 492)
        XCTAssertEqual(TranscriptScrollGeometry.bottom(contentHeight: 1_100 + reserved, viewportHeight: 800,
                                                       topInset: 100, bottomInset: 100), target)
        XCTAssertEqual(TranscriptScrollGeometry.reservation(turnOffset: target, naturalHeight: 1_400,
                                                             viewportHeight: 800, bottomInset: 100), 192)
        XCTAssertEqual(TranscriptScrollGeometry.reservation(turnOffset: target, naturalHeight: 2_000,
                                                             viewportHeight: 800, bottomInset: 100), 0)
        XCTAssertEqual(TranscriptScrollGeometry.reservation(turnOffset: target, naturalHeight: 1_100,
                                                             viewportHeight: 500, bottomInset: 100), 192)
        XCTAssertFalse(TranscriptScrollGeometry.shouldAnimate(initial: true, geometryChanged: false, reduceMotion: false))
        XCTAssertFalse(TranscriptScrollGeometry.shouldAnimate(initial: false, geometryChanged: true, reduceMotion: false))
        XCTAssertFalse(TranscriptScrollGeometry.shouldAnimate(initial: false, geometryChanged: false, reduceMotion: true))
        XCTAssertTrue(TranscriptScrollGeometry.shouldAnimate(initial: false, geometryChanged: false, reduceMotion: false))
    }
}
