import AppKit

/// Remember geometry without asking AppKit to restore a window after it appears.
/// Only the scene's initial-placement callback reads this state; observers never
/// resize or move the live window.
@MainActor final class MainWindowGeometry: NSObject {
    static let preferenceKey = "mainWindowGeometry.v1"

    struct Display {
        let id: UInt32
        let frame: CGRect
        let visibleFrame: CGRect

        init(id: UInt32, frame: CGRect, visibleFrame: CGRect) {
            self.id = id; self.frame = frame; self.visibleFrame = visibleFrame
        }

        init(_ screen: NSScreen) {
            id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            frame = screen.frame
            visibleFrame = screen.visibleFrame
        }
    }

    struct Snapshot: Codable, Equatable {
        let frame: CGRect
        let displayID: UInt32
        let visibleFrame: CGRect
        let titlebarHeight: CGFloat

        var isValid: Bool {
            Self.isValid(frame) && Self.isValid(visibleFrame) &&
                titlebarHeight.isFinite && titlebarHeight >= 0 && titlebarHeight < frame.height
        }

        static func isValid(_ rect: CGRect) -> Bool {
            rect.origin.x.isFinite && rect.origin.y.isFinite &&
                rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0 &&
                rect.maxX.isFinite && rect.maxY.isFinite
        }
    }

    struct Placement: Equatable {
        let position: CGPoint
        let size: CGSize
    }

    private let preferences: UserDefaults
    private weak var window: NSWindow?
    private var changingFullScreen = false

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        super.init()
    }

    var saved: Snapshot? {
        guard let data = preferences.data(forKey: Self.preferenceKey),
              let value = try? JSONDecoder().decode(Snapshot.self, from: data), value.isValid else { return nil }
        return value
    }

    func placement(minimumContentSize: CGSize, defaultDisplayBounds: CGRect) -> Placement? {
        let displays = NSScreen.screens.map(Display.init)
        guard let primary = displays.first else { return nil }
        // SwiftUI uses global top-left coordinates; AppKit uses bottom-left.
        let defaultID = displays.first { display in
            CGRect(x: display.frame.minX, y: primary.frame.maxY - display.frame.maxY,
                   width: display.frame.width, height: display.frame.height) == defaultDisplayBounds
        }?.id ?? primary.id
        return placement(displays: displays, defaultDisplayID: defaultID, minimumContentSize: minimumContentSize)
    }

    func placement(displays: [Display], defaultDisplayID: UInt32, minimumContentSize: CGSize) -> Placement? {
        guard let saved, let primary = displays.first,
              minimumContentSize.width.isFinite, minimumContentSize.height.isFinite else { return nil }
        let previousDisplay = displays.first { $0.id == saved.displayID }
        guard let display = previousDisplay ?? displays.first(where: { $0.id == defaultDisplayID }) ?? displays.first,
              Snapshot.isValid(display.visibleFrame) else { return nil }
        let visible = display.visibleFrame
        // Placement sizes the entire SwiftUI window, not contentLayoutRect. Keep
        // chrome in the saved size and account for it only when enforcing minima.
        let size = CGSize(width: min(visible.width, max(minimumContentSize.width, saved.frame.width)),
                          height: min(visible.height, max(minimumContentSize.height + saved.titlebarHeight, saved.frame.height)))
        let x: CGFloat
        let top: CGFloat
        if previousDisplay != nil {
            // Preserve the offset from the display's top-left even if its position,
            // resolution, menu bar or Dock changed between launches.
            x = visible.minX + saved.frame.minX - saved.visibleFrame.minX
            top = visible.maxY - (saved.visibleFrame.maxY - saved.frame.maxY)
        } else {
            x = visible.midX - size.width / 2
            top = visible.midY + size.height / 2
        }
        let fittedX = min(max(x, visible.minX), visible.maxX - size.width)
        let fittedTop = min(max(top, visible.minY + size.height), visible.maxY)
        return Placement(position: CGPoint(x: fittedX, y: primary.frame.maxY - fittedTop), size: size)
    }

    func observe(_ window: NSWindow?) {
        guard self.window !== window else { return }
        NotificationCenter.default.removeObserver(self)
        self.window = window
        changingFullScreen = false
        guard let window else { return }
        // Initial placement already supplies the final frame. AppKit's opening
        // animation can still overshoot its visible width while window.frame
        // stays unchanged; opt out before the main window is ordered onscreen.
        window.animationBehavior = .none
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
                     NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.willCloseNotification] {
            center.addObserver(self, selector: #selector(save), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(save), name: NSApplication.willTerminateNotification, object: nil)
        center.addObserver(self, selector: #selector(willEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: window)
        center.addObserver(self, selector: #selector(willExitFullScreen), name: NSWindow.willExitFullScreenNotification, object: window)
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.addObserver(self, selector: #selector(didChangeFullScreen), name: name, object: window)
        }
        // Do not capture the initial, not-yet-placed frame when the view attaches.
        // The key/move/resize notifications capture the visible window instead.
    }

    @objc private func save() {
        guard let window, window.isVisible, !window.isMiniaturized, !window.inLiveResize,
              !changingFullScreen, !window.styleMask.contains(.fullScreen), let screen = window.screen else { return }
        let value = Snapshot(frame: window.frame, displayID: Display(screen).id, visibleFrame: screen.visibleFrame,
                             titlebarHeight: max(0, window.frame.height - window.contentLayoutRect.height))
        guard value.isValid, value != saved, let data = try? JSONEncoder().encode(value) else { return }
        preferences.set(data, forKey: Self.preferenceKey)
    }

    @objc private func willEnterFullScreen() {
        save()
        changingFullScreen = true
    }

    @objc private func willExitFullScreen() { changingFullScreen = true }

    @objc private func didChangeFullScreen() {
        changingFullScreen = false
        save()
    }
}
