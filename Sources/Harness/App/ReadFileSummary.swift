import Foundation

struct ReadFileSummary {
    let path: String
    let lines: ClosedRange<Int>?

    init?(_ result: ToolResult) {
        struct Arguments: Decodable { let path: String }
        guard result.call.name == "read_file",
              let arguments = try? JSONDecoder().decode(Arguments.self, from: Data(result.call.arguments.utf8)),
              !arguments.path.isEmpty else { return nil }
        path = arguments.path
        var first: Int?
        var last: Int?
        let output = result.text.split(separator: "\n", omittingEmptySubsequences: false)
        if output.first?.hasPrefix("Revision: ") == true {
            for line in output.dropFirst() {
                guard let colon = line.firstIndex(of: ":"),
                      let number = Int(line[..<colon]), number > 0 else { break }
                if let last, number <= last || number - last != 1 { break }
                if first == nil { first = number }
                last = number
            }
        }
        if let first, let last { lines = first...last }
        else { lines = nil }
    }

    var lineLabel: String? {
        guard let lines else { return nil }
        return lines.lowerBound == lines.upperBound
            ? "Line \(lines.lowerBound)"
            : "Lines \(lines.lowerBound)–\(lines.upperBound)"
    }
}
