import AppKit

@MainActor
struct ComposerCursorTests {
    func excludesControlsWithoutLeavingGaps() throws {
        let bounds = CGRect(x: 0, y: 0, width: 820, height: 100)
        let button = CGRect(x: 776, y: 56, width: 32, height: 32)
        let attachments = CGRect(x: 12, y: 12, width: 796, height: 24)
        let view = ComposerCursor.CursorView(frame: bounds)
        view.updateTrackingAreas()
        try expect(view.trackingAreas.count == 1 && view.trackingAreas[0].rect == bounds)
        try expect(view.hitTest(NSPoint(x: 4, y: 4)) == nil)
        view.exclusions = [button, attachments]
        view.updateTrackingAreas()
        let regions = ComposerCursor.regions(in: bounds, excluding: [button, attachments])
        try expect(view.trackingAreas.count == regions.count)
        try expect(regions.allSatisfy { region in view.trackingAreas.contains { $0.rect == region } })
        for region in regions {
            try expect(bounds.contains(region))
            try expect(region.intersection(button).isEmpty)
            try expect(region.intersection(attachments).isEmpty)
        }
        let area = regions.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
        try expect(area == bounds.width * bounds.height - button.width * button.height - attachments.width * attachments.height)
    }
}
