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
        // Match the bubble's 40pt spacer, 600pt cap and 24pt horizontal padding.
        // Count graphemes rather than UTF-8 bytes, and never cap explicit lines.
        let textWidth = message.role == .user ? min(600, width - 40) - 24 : width
        let charactersPerLine = max(1, Int(max(1, textWidth) / 7))
        func wrappedLines(_ count: Int) -> CGFloat {
            CGFloat(max(1, (count + charactersPerLine - 1) / charactersPerLine))
        }
        let sourceLines = message.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if message.role == .user {
            return sourceLines.reduce(0) { $0 + wrappedLines($1.count) } * 19 + 16
        }
        // Cheap Markdown approximation only; do not parse/layout offscreen rows.
        // Ordinary soft breaks share a paragraph, while fences and block starts
        // keep their lines. Mounted rows always replace this with measured text.
        var lines: CGFloat = 0
        var paragraphCharacters = 0
        var fence: String?
        func flushParagraph() {
            if paragraphCharacters > 0 { lines += wrappedLines(paragraphCharacters); paragraphCharacters = 0 }
        }
        for sourceLine in sourceLines {
            let trimmed = sourceLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
            } else if fence != nil {
                lines += wrappedLines(sourceLine.count)
            } else if trimmed.isEmpty {
                flushParagraph()
                lines += 0.5 // Paragraph spacing, not an empty source line.
            } else if ["#", ">", "- ", "* ", "+ ", "|"].contains(where: { trimmed.hasPrefix($0) }) ||
                        trimmed.first?.isNumber == true || sourceLine.hasPrefix("    ") {
                flushParagraph()
                lines += wrappedLines(sourceLine.count)
            } else {
                paragraphCharacters += sourceLine.count + (paragraphCharacters > 0 ? 1 : 0)
                if sourceLine.hasSuffix("  ") || sourceLine.hasSuffix("\\") { flushParagraph() }
            }
        }
        flushParagraph()
        return max(1, lines) * 19
    }
}
