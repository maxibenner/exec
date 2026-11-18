import Foundation

/// A display-only unfinished-tail policy, not another Markdown parser. Foundation
/// still parses every block/link. Only recognized open fences and conservative
/// inline delimiter runs in the last paragraph receive provisional presentation.
/// Final/history rendering always uses the untouched source and canonical parser.
enum StreamingMarkdown {
    static func parse(_ source: String) -> [MarkdownBlock] {
        guard source.utf8.count <= 1_048_576 else { return MarkdownDocument.parse(source) }
        let lines = source.components(separatedBy: "\n")
        var openFence: (line: Int, marker: Character, count: Int)?
        var tailLine = 0
        for (index, line) in lines.enumerated() {
            if let open = openFence {
                if let fence = fence(in: line), fence.marker == open.marker,
                   fence.count >= open.count, fence.info.trimmingCharacters(in: .whitespaces).isEmpty {
                    openFence = nil
                    tailLine = index + 1
                }
            } else if let fence = fence(in: line),
                      fence.marker != "`" || !fence.info.contains("`") {
                openFence = (index, fence.marker, fence.count)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                tailLine = index + 1
            }
        }
        if let open = openFence {
            // Foundation already renders nonempty, unclosed fences canonically.
            // An empty opening has no attributed runs, so obtain a code-block
            // template and clear its placeholder before native rendering.
            let body = lines.dropFirst(open.line + 1).joined(separator: "\n")
            guard body.isEmpty else { return MarkdownDocument.parse(source) }
            let closing = String(repeating: String(open.marker), count: open.count)
            var code = MarkdownDocument.parse(lines[open.line] + "\n \n" + closing)
            guard code.count == 1, case .codeBlock = code[0].kind else { return MarkdownDocument.parse(source) }
            code[0].text = AttributedString()
            let prefix = lines.prefix(open.line).joined(separator: "\n")
            return (prefix.isEmpty ? [] : MarkdownDocument.parse(prefix)) + code
        }
        guard tailLine < lines.count else { return MarkdownDocument.parse(source) }
        let prefix = lines.prefix(tailLine).joined(separator: "\n")
        let tail = lines.dropFirst(tailLine).joined(separator: "\n")
        return MarkdownDocument.parse((tailLine == 0 ? "" : prefix + "\n") + projectInlineTail(tail))
    }

    private static func fence(in line: String) -> (marker: Character, count: Int, info: String)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let count = rest.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        return (marker, count, String(rest.dropFirst(count)))
    }

    private static func projectInlineTail(_ source: String) -> String {
        let chars = Array(source)
        var index = 0
        var code: (start: Int, count: Int)?
        var emphasis: [(start: Int, token: String)] = []
        func punctuation(_ char: Character?) -> Bool {
            guard let char else { return false }
            return char.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.union(.symbols).contains($0) }
        }
        while index < chars.count {
            let char = chars[index]
            if let open = code {
                // Backslashes inside code are literal; only an equal run closes.
                if char == "`" {
                    let count = chars[index...].prefix(while: { $0 == "`" }).count
                    if count == open.count { code = nil }
                    index += count
                } else { index += 1 }
                continue
            }
            if char == "\\" {
                // An escaped delimiter starts literal punctuation, not a new
                // provisional opener in the remainder of that same run.
                index += 1
                if index < chars.count {
                    let escaped = chars[index]
                    index += 1
                    if "`*_~".contains(escaped) {
                        while index < chars.count, chars[index] == escaped { index += 1 }
                    }
                }
                continue
            }
            // Never synthesize delimiters in a link destination or HTML/autolink.
            if char == "<" {
                guard let end = chars[index...].firstIndex(of: ">") else { return source }
                index = end + 1
                continue
            }
            if char == "]", index + 1 < chars.count, chars[index + 1] == "(" {
                var depth = 1
                index += 2
                while index < chars.count, depth > 0 {
                    if chars[index] == "\\" { index += min(2, chars.count - index); continue }
                    if chars[index] == "(" { depth += 1 }
                    if chars[index] == ")" { depth -= 1 }
                    index += 1
                }
                if depth > 0 { return source }
                continue
            }
            if char == "`" {
                let count = chars[index...].prefix(while: { $0 == "`" }).count
                code = (index, count)
                index += count
                continue
            }
            guard char == "*" || char == "_" || char == "~" else { index += 1; continue }
            let count = chars[index...].prefix(while: { $0 == char }).count
            // Deliberately leave triple/mixed delimiter ambiguities canonical.
            guard count <= 2, char != "~" || count == 2 else { index += count; continue }
            let before = index > 0 ? chars[index - 1] : nil
            let after = index + count < chars.count ? chars[index + count] : nil
            let left = after.map { !$0.isWhitespace } == true &&
                (!punctuation(after) || before == nil || before!.isWhitespace || punctuation(before))
            let right = before.map { !$0.isWhitespace } == true &&
                (!punctuation(before) || after == nil || after!.isWhitespace || punctuation(after))
            let token = String(repeating: String(char), count: count)
            if right, emphasis.last?.token == token {
                emphasis.removeLast()
            } else if (left && (!right || punctuation(before)) && (char != "_" || !right)) ||
                        (after == nil && (before == nil || before!.isWhitespace)) {
                emphasis.append((index, token))
            }
            index += count
        }
        var result = source
        if let code {
            if code.start + code.count == chars.count {
                result = String(chars.prefix(code.start)) // Don't flash an opening delimiter alone.
            } else {
                result += String(repeating: "`", count: code.count)
            }
        }
        if code == nil, let last = emphasis.last, last.start + last.token.count == chars.count {
            result = String(chars.prefix(last.start))
            emphasis.removeLast()
        }
        // Close before trailing whitespace, which cannot close emphasis itself.
        // This styles the arrived text without buffering an arbitrarily long span.
        let whitespace = String(result.reversed().prefix(while: \.isWhitespace).reversed())
        result = String(result.dropLast(whitespace.count)) + emphasis.reversed().map(\.token).joined() + whitespace
        return result
    }
}
