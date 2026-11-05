import Foundation

struct DiffDocument {
    enum Kind { case context, added, removed, header }
    struct Line {
        let text: String
        let kind: Kind
        var number: Int?
    }
    struct Pair {
        var before: Line?
        var after: Line?
    }
    let unified: [Line]
    let pairs: [Pair]

    init(_ source: String) {
        var raw = source.components(separatedBy: "\n")
        if raw.last == "" { raw.removeLast() }
        var unified: [Line] = []
        var pairs: [Pair] = []
        var removed: [Line] = [], added: [Line] = []
        var oldNumber = 0, newNumber = 0
        var previous: Kind = .context
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                pairs.append(Pair(before: index < removed.count ? removed[index] : nil,
                                  after: index < added.count ? added[index] : nil))
            }
            removed = []; added = []
        }
        for (index, text) in raw.enumerated() {
            if index < 2 && (text.hasPrefix("--- ") || text.hasPrefix("+++ ")) {
                unified.append(Line(text: text, kind: .header))
            } else if text.hasPrefix("@@ ") {
                flush()
                let fields = text.split(separator: " ")
                if fields.count >= 3 {
                    oldNumber = Int(fields[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    newNumber = Int(fields[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                let line = Line(text: text, kind: .header)
                unified.append(line)
                pairs.append(Pair(before: line, after: line))
                previous = .context
            } else if text.hasPrefix("-") {
                unified.append(Line(text: text, kind: .removed))
                removed.append(Line(text: String(text.dropFirst()), kind: .removed, number: oldNumber))
                oldNumber += 1; previous = .removed
            } else if text.hasPrefix("+") {
                unified.append(Line(text: text, kind: .added))
                added.append(Line(text: String(text.dropFirst()), kind: .added, number: newNumber))
                newNumber += 1; previous = .added
            } else if text.hasPrefix("\\") {
                let line = Line(text: text, kind: .header)
                unified.append(line)
                if previous == .removed { removed.append(line) }
                else if previous == .added { added.append(line) }
                else { pairs.append(Pair(before: line, after: line)) }
            } else {
                flush()
                unified.append(Line(text: text, kind: .context))
                let content = text.hasPrefix(" ") ? String(text.dropFirst()) : text
                pairs.append(Pair(before: Line(text: content, kind: .context, number: oldNumber),
                                  after: Line(text: content, kind: .context, number: newNumber)))
                oldNumber += 1; newNumber += 1; previous = .context
            }
        }
        flush()
        self.unified = unified
        self.pairs = pairs
    }
}
