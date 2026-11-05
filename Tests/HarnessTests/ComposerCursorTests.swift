import Foundation

@MainActor
struct ComposerCursorTests {
    func excludesControlsWithoutLeavingGaps() throws {
        let bounds = CGRect(x: 0, y: 0, width: 820, height: 100)
        let button = CGRect(x: 776, y: 56, width: 32, height: 32)
        let attachments = CGRect(x: 12, y: 12, width: 796, height: 24)
        let regions = ComposerCursor.regions(in: bounds, excluding: [button, attachments])
        for region in regions {
            try expect(bounds.contains(region))
            try expect(region.intersection(button).isEmpty)
            try expect(region.intersection(attachments).isEmpty)
        }
        let area = regions.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        try expect(area == bounds.width * bounds.height - button.width * button.height - attachments.width * attachments.height)
    }
}
