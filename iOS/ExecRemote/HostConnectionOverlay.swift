import SwiftUI
import UIKit

/// One scene-local indicator above app presentations, never part of page layout.
struct HostConnectionOverlay: UIViewRepresentable {
    let isVisible: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.didAttach = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ view: AttachmentView, context: Context) {
        context.coordinator.update(isVisible: isVisible)
        if let window = view.window { context.coordinator.attach(to: window) }
    }

    static func dismantleUIView(_ view: AttachmentView, coordinator: Coordinator) {
        view.didAttach = nil
        coordinator.removeWindow()
    }

    final class AttachmentView: UIView {
        var didAttach: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // A temporary removal during presentation must not replace the
            // scene's indicator. Root teardown uses dismantleUIView instead.
            if let window { didAttach?(window) }
        }
    }

    @MainActor final class Coordinator: NSObject {
        private let presentation = HostConnectionPresentation()
        private var window: HostConnectionWindow?

        func update(isVisible: Bool) { presentation.isVisible = isVisible }

        func attach(to primaryWindow: UIWindow) {
            guard let scene = primaryWindow.windowScene, window?.windowScene !== scene else { return }
            removeWindow()
            let controller = HostConnectionController(rootView: HostConnectionPill(presentation: presentation))
            controller.primaryWindow = primaryWindow
            controller.view.backgroundColor = .clear
            controller.view.isOpaque = false
            controller.view.accessibilityViewIsModal = false

            let overlay = HostConnectionWindow(windowScene: scene)
            overlay.frame = scene.coordinateSpace.bounds
            overlay.backgroundColor = .clear
            overlay.isOpaque = false
            // Above this scene's app sheets, below system status/alert levels.
            overlay.windowLevel = .normal + 1
            overlay.rootViewController = controller
            window = overlay
            NotificationCenter.default.addObserver(self, selector: #selector(sceneDisconnected),
                                                   name: UIScene.didDisconnectNotification, object: scene)
            // Never make this window key or touch the primary window's focus.
            // Keep the same transparent host even while the pill is hidden.
            overlay.isHidden = false
        }

        @objc private func sceneDisconnected() { removeWindow() }

        func removeWindow() {
            NotificationCenter.default.removeObserver(self, name: UIScene.didDisconnectNotification, object: nil)
            window?.isHidden = true
            window?.rootViewController = nil
            window?.windowScene = nil
            window = nil
        }
    }
}

@MainActor @Observable private final class HostConnectionPresentation {
    var isVisible = false
}

private final class HostConnectionWindow: UIWindow {
    override var canBecomeKey: Bool { false }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

private final class HostConnectionController: UIHostingController<HostConnectionPill> {
    weak var primaryWindow: UIWindow?
    // The primary app hierarchy still owns status-bar appearance, including
    // any presented controller. This window never supplies its own style.
    override var childForStatusBarStyle: UIViewController? { primaryWindow?.rootViewController }
    override var childForStatusBarHidden: UIViewController? { primaryWindow?.rootViewController }
}

private struct HostConnectionPill: View {
    let presentation: HostConnectionPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if presentation.isVisible {
                Label("Host connection lost", systemImage: "wifi.slash")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.12), in: Capsule())
                    .background(Color(uiColor: .systemBackground), in: Capsule())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Host connection lost")
                    .accessibilityIdentifier("host-connection-banner")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Use the scene's safe top below the Dynamic Island/status area, not
        // a page's navigation bar, sheet, scroll position or keyboard.
        .padding(.top, 6)
        .padding(.horizontal, 16)
        .ignoresSafeArea(.keyboard)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: presentation.isVisible)
    }
}
