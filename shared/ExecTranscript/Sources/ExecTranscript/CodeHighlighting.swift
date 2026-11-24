import Foundation

/// Main-actor scheduling shared by the native transcript renderers. The callback
/// receives only colors' token ranges; the renderer owns text and layout.
@MainActor public final class CodeHighlighting {
    public struct Block: Sendable {
        public let source: String
        public let language: String?
        /// UTF-16 range occupied by the exact source in the renderer's text.
        public let range: NSRange

        public init(source: String, language: String?, range: NSRange) {
            self.source = source
            self.language = language
            self.range = range
        }
    }

    // Injection stays internal: production clients always share the actor's cache.
    typealias Worker = @Sendable (String, String?, UUID) async -> [SyntaxToken]
    typealias Release = @Sendable (UUID) async -> Void
    enum Limits {
        static let blocks = 24
        static let tokens = 16_384
    }
    private struct Work: Sendable {
        let generation: UInt64
        let blocks: [Block]
        let documentIDs: [UUID]
    }
    private struct Result {
        let blocks: [Block]
        let tokens: [SyntaxToken]
    }

    private let apply: @MainActor ([SyntaxToken]) -> Void
    private let worker: Worker
    private let release: Release
    private let delay: Duration
    private var blocks: [Block] = []
    // A fence's ordinal remains stable as its source streams or its rendered range moves.
    private var documentIDs: [UUID] = []
    private var activeDocumentIDs: Set<UUID> = []
    private var retiredDocumentIDs: Set<UUID> = []
    private var generation: UInt64 = 0
    private var pending: Work?
    private var deadline: ContinuousClock.Instant?
    private var task: Task<Void, Never>?
    private var taskID: UUID?
    private var previous: Result?

    public convenience init(apply: @escaping @MainActor ([SyntaxToken]) -> Void) {
        self.init(delay: .milliseconds(60), worker: { source, language, id in
            await CodeHighlighter.shared.highlight(source, language: language, documentID: id)
        }, release: { id in
            await CodeHighlighter.shared.release(documentID: id)
        }, apply: apply)
    }

    init(delay: Duration, worker: @escaping Worker, release: @escaping Release = { _ in },
         apply: @escaping @MainActor ([SyntaxToken]) -> Void) {
        self.delay = delay
        self.worker = worker
        self.release = release
        self.apply = apply
    }

    public func update(_ input: [Block]) {
        let next = Array(input.prefix(Limits.blocks))
        if Self.matches(blocks, next) {
            // Base attributed text may have been replaced even though code did not change.
            if let previous, Self.matches(previous.blocks, next) { apply(previous.tokens) }
            return
        }
        generation &+= 1
        blocks = next
        if documentIDs.count > next.count {
            let removed = Set(documentIDs.dropFirst(next.count))
            documentIDs = Array(documentIDs.prefix(next.count))
            retiredDocumentIDs.formUnion(removed.intersection(activeDocumentIDs))
            releaseDocuments(removed.subtracting(activeDocumentIDs))
        }
        while documentIDs.count < next.count { documentIDs.append(UUID()) }
        if let previous, Self.matches(previous.blocks, next) {
            pending = nil
            deadline = nil
            apply(previous.tokens)
            return
        }
        pending = Work(generation: generation, blocks: next, documentIDs: documentIDs)
        // Anchor to the FIRST pending update, not the latest streaming fragment.
        if deadline == nil { deadline = .now + delay }
        schedule()
    }

    public func reset() {
        generation &+= 1
        task?.cancel()
        task = nil
        taskID = nil
        pending = nil
        deadline = nil
        releaseDocuments(Set(documentIDs).union(activeDocumentIDs).union(retiredDocumentIDs))
        blocks = []
        documentIDs = []
        activeDocumentIDs = []
        retiredDocumentIDs = []
        previous = nil
        apply([])
    }

    deinit {
        task?.cancel()
        let ids = Set(documentIDs).union(activeDocumentIDs).union(retiredDocumentIDs)
        let release = release
        Task { for id in ids { await release(id) } }
    }

    private func schedule() {
        guard task == nil, pending != nil, let deadline else { return }
        let id = UUID()
        taskID = id
        let worker = worker, release = release
        task = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard let work = self?.takePending(taskID: id) else {
                self?.finish(taskID: id)
                return
            }
            var tokens: [SyntaxToken] = []
            for (block, documentID) in zip(work.blocks, work.documentIDs) {
                guard !Task.isCancelled, tokens.count < Limits.tokens else { break }
                let range = block.range
                // Reject malformed host ranges rather than coloring surrounding prose.
                guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
                      range.length <= Int.max - range.location,
                      range.length == block.source.utf16.count else { continue }
                let local = await worker(block.source, block.language, documentID)
                // A streaming update may supersede this set while its worker is suspended.
                // Finish below to release retired sessions and start the latest pending set.
                guard !Task.isCancelled, self?.taskID == id,
                      self?.generation == work.generation else { break }
                for token in local {
                    guard tokens.count < Limits.tokens else { break }
                    let span = token.range
                    guard span.location >= 0, span.length > 0, span.location <= range.length,
                          span.length <= range.length - span.location else { continue }
                    tokens.append(SyntaxToken(range: NSRange(location: range.location + span.location,
                                                            length: span.length), kind: token.kind))
                }
            }
            if Task.isCancelled {
                // A worker may ignore cancellation. Release AFTER it returns as well as
                // on reset/deinit, so it cannot resurrect an abandoned parser session.
                for documentID in work.documentIDs { await release(documentID) }
            } else {
                self?.finish(taskID: id, work: work, tokens: tokens)
            }
        }
    }

    private func takePending(taskID: UUID) -> Work? {
        guard self.taskID == taskID, let work = pending else { return nil }
        pending = nil
        deadline = nil
        activeDocumentIDs = Set(work.documentIDs)
        return work
    }

    private func finish(taskID: UUID, work: Work? = nil, tokens: [SyntaxToken] = []) {
        guard self.taskID == taskID else { return }
        task = nil
        self.taskID = nil
        activeDocumentIDs = []
        releaseDocuments(retiredDocumentIDs)
        retiredDocumentIDs = []
        if let work, work.generation == generation {
            previous = Result(blocks: work.blocks, tokens: tokens)
            apply(tokens)
        }
        schedule()
    }

    private func releaseDocuments(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let release = release
        Task { for id in ids { await release(id) } }
    }

    private static func matches(_ lhs: [Block], _ rhs: [Block]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            a.range == b.range && a.language == b.language && a.source.utf8.elementsEqual(b.source.utf8)
        }
    }
}
