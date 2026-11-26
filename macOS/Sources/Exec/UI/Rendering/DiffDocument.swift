import Foundation

struct DiffDocument {
    enum Kind { case context, added, removed, header, note }
    struct Line {
        let text: String
        let kind: Kind
        let number: Int?
        var emphasis: NSRange? = nil
    }

    let lines: [Line]

    init(_ source: String) {
        var lines: [Line] = []
        var removed: [Int] = [], added: [Int] = []
        var oldNumber: Int?, newNumber: Int?

        func finishChanges() {
            for (offset, index) in removed.enumerated() {
                let peer = offset < added.count ? lines[added[offset]].text : nil
                lines[index].emphasis = Self.changedSpan(in: lines[index].text, comparedTo: peer)
            }
            for (offset, index) in added.enumerated() {
                let peer = offset < removed.count ? lines[removed[offset]].text : nil
                lines[index].emphasis = Self.changedSpan(in: lines[index].text, comparedTo: peer)
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }

        for (raw, kind) in Self.sourceLines(source) {
            let text = raw.last == "\r" ? String(raw.dropLast()) : raw
            switch kind {
            case .header:
                guard text.hasPrefix("@@ ") else { continue }
                finishChanges()
                if !lines.isEmpty { lines.append(Line(text: "", kind: .context, number: nil)) }
                let fields = text.split(separator: " ")
                if fields.count >= 4, fields[3] == "@@" {
                    oldNumber = Self.hunkStart(fields[1], sign: "-")
                    newNumber = Self.hunkStart(fields[2], sign: "+")
                } else {
                    oldNumber = nil
                    newNumber = nil
                }
            case .removed:
                removed.append(lines.count)
                lines.append(Line(text: String(text.dropFirst()), kind: kind, number: Self.advance(&oldNumber)))
            case .added:
                added.append(lines.count)
                lines.append(Line(text: String(text.dropFirst()), kind: kind, number: Self.advance(&newNumber)))
            case .context:
                finishChanges()
                if text.hasPrefix(" ") {
                    _ = Self.advance(&oldNumber)
                    lines.append(Line(text: String(text.dropFirst()), kind: kind, number: Self.advance(&newNumber)))
                } else {
                    lines.append(Line(text: text, kind: kind, number: nil))
                }
            case .note:
                // A missing-final-newline annotation does not break a replacement pair.
                lines.append(Line(text: text, kind: kind, number: nil))
            }
        }
        finishChanges()
        self.lines = lines
    }

    // Keep the original patch available to the approval prompt, including the target path.
    static func sourceLines(_ source: String) -> [(text: String, kind: Kind)] {
        var raw = source.components(separatedBy: "\n")
        if raw.last == "" { raw.removeLast() }
        let hasFileHeaders = raw.count >= 2 && raw[0].hasPrefix("--- ") && raw[1].hasPrefix("+++ ")
        return raw.enumerated().map { index, text in
            let kind: Kind
            if (hasFileHeaders && index < 2) || text.hasPrefix("@@ ") { kind = .header }
            else if text.hasPrefix("-") { kind = .removed }
            else if text.hasPrefix("+") { kind = .added }
            else if text.hasPrefix("\\") || text == "[Diff preview truncated; not a complete patch.]" { kind = .note }
            else { kind = .context }
            return (text, kind)
        }
    }

    private static func hunkStart(_ field: Substring, sign: Character) -> Int? {
        guard field.first == sign, let value = Int(field.dropFirst().prefix(while: { $0 != "," })),
              value >= 0 else { return nil }
        return value
    }

    private static func advance(_ number: inout Int?) -> Int? {
        guard let value = number else { return nil }
        number = value < Int.max ? value + 1 : nil
        return value > 0 ? value : nil
    }

    private static func changedSpan(in text: String, comparedTo peer: String?) -> NSRange? {
        let start: String.Index
        var end = text.endIndex
        if let peer {
            let prefix = zip(text, peer).prefix(while: { $0.0 == $0.1 }).count
            start = text.index(text.startIndex, offsetBy: prefix)
            let peerStart = peer.index(peer.startIndex, offsetBy: prefix)
            for (left, right) in zip(text[start...].reversed(), peer[peerStart...].reversed()) {
                guard left == right else { break }
                text.formIndex(before: &end)
            }
        } else {
            start = text.firstIndex(where: { !$0.isWhitespace }) ?? end
        }
        return start < end ? NSRange(start..<end, in: text) : nil
    }
}
