import Foundation
import CoreFoundation

/// A bounded, deliberately simple HTML-to-text reader. It never loads resources,
/// executes scripts, or asks another model to rewrite the page.
enum PageText {
    static func extract(_ data: Data, mime: String, charset: String?) throws -> String {
        let encoding: String.Encoding
        if let charset {
            let value = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            guard value != kCFStringEncodingInvalidId else { throw ExecError("Unsupported page text encoding.") }
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
        } else {
            encoding = String(data: data, encoding: .utf8) == nil ? .windowsCP1252 : .utf8
        }
        guard var text = String(data: data, encoding: encoding) else { throw ExecError("The page text could not be decoded.") }
        if mime == "text/html" || mime == "application/xhtml+xml" {
            text = replace(#"(?s)<!--.*?(?:-->|$)"#, in: text, with: "")
            text = replace(#"(?is)<(script|style|template|noscript)\b[^>]*>.*?(?:</\1\s*>|$)"#, in: text, with: "")
            text = replace(#"(?i)</?(?:p|div|section|article|header|footer|nav|main|h[1-6]|li|ul|ol|table|tr|blockquote|pre|br|hr)\b[^>]*>"#, in: text, with: "\n")
            text = replace(#"<[^>]*>"#, in: text, with: "")
            text = decodeEntities(text)
            text = replace(#"[\t\x{00a0} ]+"#, in: text, with: " ")
            text = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            text = replace(#"\n{3,}"#, in: text, with: "\n\n")
        }
        // Remove terminal/control codes while preserving ordinary text layout.
        text = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || "\n\r\t".unicodeScalars.contains($0) })
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func decodeEntities(_ text: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
                     "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
                     "hellip": "…", "copy": "©", "reg": "®", "bull": "•"]
        let regex = try! NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]{1,8}|#[0-9]{1,10}|[a-zA-Z]{2,10});"#)
        let source = text as NSString
        var output = ""
        var offset = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: offset, length: match.range.location - offset))
            let entity = source.substring(with: match.range(at: 1))
            var value = named[entity]
            if entity.hasPrefix("#") {
                let hex = entity.hasPrefix("#x")
                if let code = UInt32(entity.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(code) {
                    value = String(scalar)
                }
            }
            output += value ?? source.substring(with: match.range)
            offset = NSMaxRange(match.range)
        }
        output += source.substring(from: offset)
        return output
    }
}
