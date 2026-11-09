import Foundation

/// Geometry for the whole transcript, without a view per message. Unknown rows use
/// estimates; measuring a row changes geometry while the reader's anchor stays fixed.
struct TranscriptLayout {
    struct Anchor: Equatable {
        let id: UUID
        let offset: CGFloat
    }
    private(set) var ids: [UUID] = []
    private(set) var offsets: [CGFloat] = []
    private(set) var heights: [CGFloat] = []
    private(set) var width: CGFloat = 0
    private(set) var totalHeight: CGFloat = 40
    // Last measured heights are estimates until a mounted row confirms them
    // for the current content/width. They also survive conversation switches.
    private var measured: [UUID: CGFloat] = [:]
    private var indices: [UUID: Int] = [:]
    static let spacing: CGFloat = 24

    /// Synchronize identities only when conversation data changes, not on every
    /// scroll/layout callback. Width-only updates leave the index untouched.
    mutating func update(messages: [Message], width: CGFloat) {
        let ids = messages.map(\.id)
        guard self.ids != ids else {
            resize(to: width)
            return
        }
        self.width = width
        self.ids = ids
        indices = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        measured = measured.filter { indices[$0.key] != nil }
        heights = messages.map { measured[$0.id] ?? Self.estimate($0, width: width) }
        rebuildOffsets()
    }

    /// Retain last-known geometry as estimates instead of replacing it with
    /// character counts at every animation width. Resetting the entire document
    /// can temporarily pull unrelated rows into the viewport and recycle selected
    /// text. Mounted rows must be remeasured at their new width; offscreen rows
    /// are always measured on mount, before their frames are committed.
    mutating func resize(to width: CGFloat) {
        self.width = width
    }

    @discardableResult
    mutating func measure(_ id: UUID, height: CGFloat) -> Bool {
        measure([(id: id, height: height)])
    }

    /// Commit the visible rows together so each settling pass rebuilds offsets
    /// at most once, rather than once per corrected row.
    @discardableResult
    mutating func measure(_ measurements: [(id: UUID, height: CGFloat)]) -> Bool {
        var changed = false
        for (id, height) in measurements {
            guard let index = indices[id], height.isFinite else { continue }
            let height = max(1, ceil(height))
            measured[id] = height
            if abs(heights[index] - height) >= 1 {
                heights[index] = height
                changed = true
            }
        }
        if changed { rebuildOffsets() }
        return changed
    }

    func anchor(at y: CGFloat) -> Anchor? {
        guard !ids.isEmpty else { return nil }
        let index = index(at: y)
        return Anchor(id: ids[index], offset: y - offsets[index])
    }

    func position(of anchor: Anchor) -> CGFloat? {
        guard let index = indices[anchor.id] else { return nil }
        return offsets[index] + min(anchor.offset, heights[index] + Self.spacing - 1)
    }

    func visibleRange(y: CGFloat, height: CGFloat, overscan: CGFloat) -> Range<Int> {
        guard !ids.isEmpty else { return 0..<0 }
        let first = index(at: max(0, y - overscan))
        let last = index(at: y + max(0, height) + overscan)
        return first..<min(ids.count, last + 1)
    }

    private func index(at y: CGFloat) -> Int {
        var low = 0
        var high = offsets.count
        while low < high {
            let middle = (low + high) / 2
            if offsets[middle] <= y { low = middle + 1 }
            else { high = middle }
        }
        return max(0, low - 1)
    }

    private mutating func rebuildOffsets() {
        var y: CGFloat = 20
        offsets = heights.map { height in
            defer { y += height + Self.spacing }
            return y
        }
        totalHeight = ids.isEmpty ? 40 : y - Self.spacing + 32
    }

    private static func estimate(_ message: Message, width: CGFloat) -> CGFloat {
        if message.toolResult != nil || message.pendingTool != nil { return 80 }
        let charactersPerLine = max(20, Int(max(100, width) / 7))
        let lines = max(1, message.text.utf8.count / charactersPerLine + 1)
        return CGFloat(min(100, lines)) * 20 + (message.role == .user ? 16 : 0)
    }
}
