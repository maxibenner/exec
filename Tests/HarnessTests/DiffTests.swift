import Foundation

struct DiffTests {
    func pairsReplacementsWithoutLosingMarkersOrPlusSigns() throws {
        let source = "--- \"file\"\n+++ \"file\"\n@@ -3,2 +3,3 @@\n context\n-old\n\\ No newline at end of file\n+++counter\n+second\n\\ No newline at end of file\n"
        let document = DiffDocument(source)
        try expect(document.unified.map(\.text).joined(separator: "\n") + "\n" == source)
        try expect(document.unified[6].kind == .added)
        try expect(document.pairs[1].before?.number == 3 && document.pairs[1].after?.number == 3)
        try expect(document.pairs[2].before?.text == "old" && document.pairs[2].after?.text == "++counter")
        try expect(document.pairs[3].before?.text == "\\ No newline at end of file")
        try expect(document.pairs[3].after?.number == 5)
        try expect(document.pairs.last?.before == nil && document.pairs.last?.after?.text == "\\ No newline at end of file")
    }
}
