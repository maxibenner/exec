import XCTest
import ExecRemote
@testable import ExecRemoteStore

final class TranscriptScrollTests: XCTestCase {
    private func message(_ id: String, _ role: String = "user", text: String = "Fixture") -> RemoteJSON {
        .object(["id": .string(id), "role": .string(role), "text": .string(text)])
    }
    private func snapshot(_ messages: [RemoteJSON], active: String? = nil, pending: [RemoteJSON] = []) -> RemoteJSON {
        .object(["id": .string("fixture"), "messages": .array(messages), "activeToolCallID": .optional(active),
                 "pendingInput": .array(pending)])
    }
    private func rows(_ messages: [RemoteJSON], pending: [RemoteJSON] = []) -> [RemoteTranscriptRow] {
        TranscriptItem.project(snapshot(messages, pending: pending)).flatMap(\.rows)
    }

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

    func testQueuedPromotionKeepsLatestFollowingOrReading() {
        let queued = message("local-queue")
        XCTAssertTrue(rows([], pending: [queued]).isEmpty, "A cold queue is not transcript history")
        let history = [message("old-user"), message("old-answer", "assistant")]
        for reading in [false, true] {
            var state = TranscriptScrollState()
            state.restoreRows(rows(history, pending: [queued]))
            if reading { state.readerScrolled(towardLatest: false, atBottom: false) }
            XCTAssertFalse(state.update(rows: rows(history)), "Expiry must not affect the transcript")
            XCTAssertFalse(state.update(rows: rows(history, pending: [queued])))

            let promoted = rows(history + [message("host-queue"), queued], pending: [queued])
            XCTAssertEqual(promoted.map(\.id), ["old-user", "old-answer", "host-queue", "local-queue"])
            XCTAssertFalse(state.update(rows: promoted))
            XCTAssertEqual(state.intent, reading ? .reading : .latest)
            XCTAssertNil(state.reservedTurnID)
        }
    }

    func testExplicitSendFromReadingPinsExactRowWithCoalescedResponseAndOtherInput() {
        var state = TranscriptScrollState()
        let history = [message("old")]
        state.restoreRows(rows(history))
        state.readerScrolled(towardLatest: false, atBottom: false)
        let otherInput = [message("local-queue"), message("response", "assistant", text: "Already answering")]
        XCTAssertFalse(state.update(rows: rows(history + otherInput), pinTo: "local-send"))
        XCTAssertEqual(state.intent, .reading, "Don't pin another row while the intended row is missing")
        let turn = rows(history + [message("local-send")] + otherInput)
        XCTAssertTrue(state.update(rows: turn, pinTo: "local-send"))
        XCTAssertEqual(state.intent, .turn("local-send"))
        XCTAssertEqual(state.reservedTurnID, "local-send")
        XCTAssertFalse(state.update(rows: turn + rows([message("more-queued-input")])))
        XCTAssertEqual(state.intent, .turn("local-send"), "Later promotions do not replace the existing turn pin")
    }

    func testOnlyAnExplicitDownwardScrollToBottomResumesFollowing() {
        var state = TranscriptScrollState()
        _ = state.update(rows: rows([message("local-send")]), pinTo: "local-send")
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

    func testRestorationAdoptsHiddenUpdatesWithoutReplayingASend() {
        var state = TranscriptScrollState()
        state.restoreRows(rows([message("old")]))
        state.readerScrolled(towardLatest: false, atBottom: false)
        let cached = rows([message("old"), message("local-delivered-while-hidden")])
        state.restoreRows(cached)
        XCTAssertEqual(state.intent, .reading)
        XCTAssertFalse(state.update(rows: cached))
        XCTAssertTrue(state.update(rows: cached + rows([message("local-next")]), pinTo: "local-next"))
        XCTAssertEqual(state.intent, .turn("local-next"))
    }

    func testRestorationDropsATurnRemovedByHistoryReset() {
        var state = TranscriptScrollState()
        _ = state.update(rows: rows([message("local-send")]), pinTo: "local-send")
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

    func testDisclosureLeavesFollowingAndOnlyExplicitBottomReentryResumes() {
        var state = TranscriptScrollState()
        let history = rows([message("question"), message("answer", "assistant")])
        _ = state.update(rows: history)
        state.disclosedTool()
        XCTAssertEqual(state.intent, .reading)
        // Group expansion, collapse, streaming and geometry are not reader input.
        _ = state.update(rows: history)
        _ = state.update(rows: rows([message("question"), message("answer", "assistant", text: "Growing")]))
        state.disclosedTool()
        XCTAssertEqual(state.intent, .reading)
        state.readerScrolled(towardLatest: false, atBottom: true)
        XCTAssertEqual(state.intent, .reading)
        state.readerScrolled(towardLatest: true, atBottom: false)
        XCTAssertEqual(state.intent, .reading)
        state.readerScrolled(towardLatest: true, atBottom: true)
        XCTAssertEqual(state.intent, .latest)
        XCTAssertTrue(state.update(rows: history + rows([message("local-question")]), pinTo: "local-question"))
        state.disclosedTool()
        XCTAssertEqual(state.intent, .reading)
        XCTAssertEqual(state.reservedTurnID, "local-question", "Do not collapse reserved response space underneath a reader")
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
