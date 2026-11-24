import XCTest
@testable import ExecTranscript

private actor SchedulingWorker {
    struct Call: Sendable {
        let source: String
        let documentID: UUID
    }
    private(set) var calls: [Call] = []
    private(set) var releases: [UUID] = []
    private var waiters: [CheckedContinuation<[SyntaxToken], Never>] = []
    private var suspended: Bool
    let tokenCount: Int

    init(suspended: Bool = false, tokenCount: Int = 1) {
        self.suspended = suspended
        self.tokenCount = tokenCount
    }
    func highlight(_ source: String, language: String?, documentID: UUID) async -> [SyntaxToken] {
        calls.append(Call(source: source, documentID: documentID))
        if suspended { return await withCheckedContinuation { waiters.append($0) } }
        return Array(repeating: SyntaxToken(range: NSRange(location: 0, length: source.utf16.count),
                                           kind: .keyword), count: tokenCount)
    }
    func resume() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(returning: [SyntaxToken(range: NSRange(location: 0, length: 1), kind: .number)])
    }
    func resumeAll() {
        suspended = false
        while !waiters.isEmpty { resume() }
    }
    func release(_ id: UUID) { releases.append(id) }
}

@MainActor final class CodeHighlightingTests: XCTestCase {
    private func block(_ source: String, at offset: Int = 0) -> CodeHighlighting.Block {
        .init(source: source, language: "swift", range: NSRange(location: offset, length: source.utf16.count))
    }
    private func eventually(_ condition: @MainActor () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for scheduler", file: file, line: line)
    }
    private func scheduler(_ worker: SchedulingWorker, delay: Duration = .milliseconds(2),
                           apply: @escaping @MainActor ([SyntaxToken]) -> Void) -> CodeHighlighting {
        CodeHighlighting(delay: delay, worker: { source, language, id in
            await worker.highlight(source, language: language, documentID: id)
        }, release: { await worker.release($0) }, apply: apply)
    }

    func testOnlyLatestPendingSetRunsAndStaleActiveResultIsRejected() async {
        let worker = SchedulingWorker(suspended: true)
        var applications: [[SyntaxToken]] = []
        let highlighting = scheduler(worker) { applications.append($0) }
        highlighting.update([block("first")])
        await eventually { await worker.calls.count == 1 }
        highlighting.update([block("discarded", at: 10)])
        highlighting.update([block("latest", at: 20)])
        try? await Task.sleep(for: .milliseconds(15))
        let activeCalls = await worker.calls
        XCTAssertEqual(activeCalls.count, 1)
        await worker.resume()
        await eventually { await worker.calls.count == 2 }
        XCTAssertTrue(applications.isEmpty)
        let calls = await worker.calls
        XCTAssertEqual(calls.map(\.source), ["first", "latest"])
        XCTAssertEqual(calls.first?.documentID, calls.last?.documentID, "Streaming retains its incremental document.")
        await worker.resume()
        await eventually { applications.count == 1 }
        XCTAssertEqual(applications.first, [SyntaxToken(range: NSRange(location: 20, length: 1), kind: .number)])
    }

    func testStaleMultiblockWorkSkipsRemainingBlocksAndReleasesRetiredSessions() async {
        let worker = SchedulingWorker(suspended: true)
        var applications: [[SyntaxToken]] = []
        let highlighting = scheduler(worker) { applications.append($0) }
        highlighting.update([block("old first"), block("old second", at: 20), block("old third", at: 40)])
        await eventually { await worker.calls.count == 1 }
        let firstID = await worker.calls.first?.documentID
        highlighting.update([block("discarded", at: 60)])
        highlighting.update([block("latest", at: 80)])
        // The coalescing deadline elapses while the first old block is suspended.
        try? await Task.sleep(for: .milliseconds(15))
        await worker.resume()
        await eventually { await worker.calls.count == 2 }
        let activeCalls = await worker.calls
        XCTAssertEqual(activeCalls.map(\.source), ["old first", "latest"])
        XCTAssertEqual(activeCalls.last?.documentID, firstID, "The retained ordinal keeps its parser session.")
        XCTAssertTrue(applications.isEmpty, "No partial or stale tokens may be applied.")
        await eventually { await worker.releases.count == 2 }
        let retired = await worker.releases
        XCTAssertEqual(Set(retired).count, 2)
        XCTAssertFalse(retired.contains { $0 == firstID })

        await worker.resumeAll()
        await eventually { applications.count == 1 }
        XCTAssertEqual(applications.first, [SyntaxToken(range: NSRange(location: 80, length: 1), kind: .number)])
        let finishedCalls = await worker.calls
        XCTAssertEqual(finishedCalls.map(\.source), ["old first", "latest"])
        highlighting.reset()
        await eventually { await worker.releases.count == 3 }
        let released = await worker.releases
        XCTAssertEqual(Set(released).count, 3, "Both retired and retained sessions are released.")
    }

    func testContinuousStreamingDoesNotKeepDeferringTheCoalescingWindow() async {
        let worker = SchedulingWorker()
        var applications: [[SyntaxToken]] = []
        let highlighting = scheduler(worker, delay: .milliseconds(20)) { applications.append($0) }
        var parsedDuringStreaming = false
        for index in 0..<30 {
            highlighting.update([block("value\(index)", at: index * 10)])
            if await worker.calls.count > 0 { parsedDuringStreaming = true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(parsedDuringStreaming, "A trailing-edge debounce would starve while updates continue.")
        await eventually { applications.last?.first?.range.location == 290 }
        let calls = await worker.calls
        XCTAssertLessThan(calls.count, 30)
        XCTAssertEqual(Set(calls.map(\.documentID)).count, 1)
    }

    func testIdenticalInputsReapplyWithoutWorkAndMapUTF16RangesAcrossFences() async {
        let worker = SchedulingWorker()
        var applications: [[SyntaxToken]] = []
        let highlighting = scheduler(worker) { applications.append($0) }
        let blocks = [block("😀e\u{301}", at: 7), block("let", at: 30)]
        highlighting.update(blocks)
        await eventually { applications.count == 1 }
        let expected = [SyntaxToken(range: NSRange(location: 7, length: 4), kind: .keyword),
                        SyntaxToken(range: NSRange(location: 30, length: 3), kind: .keyword)]
        XCTAssertEqual(applications.first, expected)
        highlighting.update(blocks)
        XCTAssertEqual(applications.count, 2, "Reapply is synchronous when base attributed text is replaced.")
        XCTAssertEqual(applications.last, expected)
        let calls = await worker.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Set(calls.map(\.documentID)).count, 2)
    }

    func testCanonicalEquivalentSourcesWithEqualUTF16LengthsAreNotIdenticalInputs() async {
        let first = "e\u{301}\u{323}"
        let second = "e\u{323}\u{301}"
        XCTAssertEqual(first, second) // Swift's canonical equality is deliberately insufficient.
        XCTAssertEqual(first.utf16.count, second.utf16.count)
        let worker = SchedulingWorker()
        var count = 0
        let highlighting = scheduler(worker) { _ in count += 1 }
        highlighting.update([block(first)])
        await eventually { count == 1 }
        highlighting.update([block(second)])
        await eventually { count == 2 }
        let calls = await worker.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last.map { Array($0.source.utf8) }, Array(second.utf8))
    }

    func testResetRejectsNonCooperativeWorkAndReleasesItsSessionAfterCompletion() async {
        let worker = SchedulingWorker(suspended: true)
        var applications: [[SyntaxToken]] = []
        let highlighting = scheduler(worker) { applications.append($0) }
        highlighting.update([block("old"), block("abandoned", at: 20)])
        await eventually { await worker.calls.count == 1 }
        let oldID = await worker.calls.first?.documentID
        highlighting.reset()
        XCTAssertEqual(applications, [[]])
        highlighting.update([block("new", at: 8)])
        await eventually { await worker.calls.count == 2 }
        await worker.resume() // Old worker ignores cancellation until it completes.
        await eventually { await worker.releases.filter { $0 == oldID }.count >= 2 }
        XCTAssertEqual(applications, [[]])
        await worker.resume()
        await eventually { applications.count == 2 }
        XCTAssertEqual(applications.last?.first?.range.location, 8)
        let calls = await worker.calls
        XCTAssertEqual(calls.map(\.source), ["old", "new"])
        XCTAssertNotEqual(calls.first?.documentID, calls.last?.documentID)
    }

    func testDeinitDoesNotRetainSchedulerAcrossWorkerAwaitAndReleasesSession() async {
        let worker = SchedulingWorker(suspended: true)
        var highlighting: CodeHighlighting? = scheduler(worker) { _ in XCTFail("Abandoned work applied") }
        let isAlive = { [weak highlighting] in highlighting != nil }
        highlighting?.update([block("old"), block("abandoned", at: 20)])
        await eventually { await worker.calls.count == 1 }
        highlighting = nil
        XCTAssertFalse(isAlive())
        await worker.resume()
        await eventually { await worker.releases.count >= 4 }
        let calls = await worker.calls
        XCTAssertEqual(calls.map(\.source), ["old"])
    }

    func testBlockAndAggregateTokenBudgetsAndInvalidRanges() async {
        let worker = SchedulingWorker()
        var applications: [[SyntaxToken]] = []
        let highlighting = scheduler(worker) { applications.append($0) }
        highlighting.update((0..<40).map { block("x", at: $0 * 2) })
        await eventually { applications.count == 1 }
        let calls = await worker.calls
        XCTAssertEqual(calls.count, CodeHighlighting.Limits.blocks)
        XCTAssertEqual(applications.first?.count, CodeHighlighting.Limits.blocks)
        highlighting.update([.init(source: "x", language: "swift", range: NSRange(location: Int.max, length: 1)),
                             .init(source: "x", language: "swift", range: NSRange(location: 0, length: 2))])
        await eventually { applications.count == 2 }
        XCTAssertEqual(applications.last, [])
        let afterInvalid = await worker.calls
        XCTAssertEqual(afterInvalid.count, calls.count)

        let prolific = SchedulingWorker(tokenCount: 10_000)
        var tokens: [SyntaxToken]?
        let capped = scheduler(prolific) { tokens = $0 }
        capped.update((0..<10).map { block("x", at: $0 * 2) })
        await eventually { tokens != nil }
        XCTAssertEqual(tokens?.count, CodeHighlighting.Limits.tokens)
        let prolificCalls = await prolific.calls
        XCTAssertEqual(prolificCalls.count, 2)
    }
}
