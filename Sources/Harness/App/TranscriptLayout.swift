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
    private var measured: [UUID: CGFloat] = [:]
    private var indices: [UUID: Int] = [:]
    static let spacing: CGFloat = 24

    mutating func update(messages: [Message], width: CGFloat) {
        let ids = messages.map(\.id)
        guard self.ids != ids || self.width != width else { return }
        if self.width != width { measured.removeAll(keepingCapacity: true) }
        self.width = width
        self.ids = ids
        indices = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        measured = measured.filter { indices[$0.key] != nil }
        heights = messages.map { measured[$0.id] ?? Self.estimate($0, width: width) }
        rebuildOffsets()
    }

    @discardableResult
    mutating func measure(_ id: UUID, height: CGFloat) -> Bool {
        guard let index = indices[id], height.isFinite else { return false }
        let height = max(1, ceil(height))
        measured[id] = height
        guard abs(heights[index] - height) >= 1 else { return false }
        heights[index] = height
        rebuildOffsets()
        return true
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
        if message.toolResult != nil { return 80 }
        let charactersPerLine = max(20, Int(max(100, width) / 7))
        let lines = max(1, message.text.utf8.count / charactersPerLine + 1)
        return CGFloat(min(100, lines)) * 20 + (message.role == .user ? 16 : 0)
    }
}
