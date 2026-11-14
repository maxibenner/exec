import Foundation

public struct ReadFileSummary {
    public let path: String
    public let lines: ClosedRange<Int>?

    public init?(name: String, arguments: String, output: String) {
        struct Arguments: Decodable { let path: String }
        guard name == "read_file",
              let arguments = try? JSONDecoder().decode(Arguments.self, from: Data(arguments.utf8)),
              !arguments.path.isEmpty else { return nil }
        path = arguments.path
        var first: Int?
        var last: Int?
        let output = output.split(separator: "\n", omittingEmptySubsequences: false)
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

    public var lineLabel: String? {
        guard let lines else { return nil }
        return lines.lowerBound == lines.upperBound
            ? "Line \(lines.lowerBound)"
            : "Lines \(lines.lowerBound)–\(lines.upperBound)"
    }
}
