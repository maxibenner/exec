import SwiftUI

/// Animate the allocated family height, not only its drawing. A native List row
/// otherwise adopts the new fitting size before its children finish transitioning.
struct SidebarAnimatedHeight: ViewModifier {
    let animation: Animation?
    @State private var measured: CGSize?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { updated in
                // Same-width corrections can arrive after child IDs reconcile.
                // Retarget them, but never animate initial sizing or a resize.
                withAnimation(measured?.width == updated.width ? animation : nil) {
                    measured = updated
                }
            }
            .modifier(InterpolatedHeight(height: measured?.height ?? 0))
    }

    struct InterpolatedHeight: AnimatableModifier {
        nonisolated var height: CGFloat
        nonisolated var animatableData: CGFloat {
            get { height }
            set { height = newValue }
        }

        func body(content: Content) -> some View {
            content.frame(height: height > 0 ? height : nil, alignment: .top)
        }
    }
}

/// List does not reliably run insertion transitions within an existing row.
/// Use a separate opacity transaction; removal uses the row's opacity transition.
struct SidebarChildAppearance: ViewModifier {
    let visible: Bool
    let animation: Animation?
    let reveal: () -> Void

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .onChange(of: visible, initial: true) { _, visible in
                // Rapid removal/reinsertion can retain the view without onAppear.
                guard !visible else { return }
                withAnimation(animation, reveal)
            }
    }
}
