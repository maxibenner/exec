import SwiftUI

/// Interpolate the row's layout height, not just its rendered content, so the
/// native List can lay out neighboring rows at each intermediate size.
struct SidebarAnimatedHeight: ViewModifier {
    let children: [UUID]
    let animation: Animation?
    @State private var measured: Measurement?

    private struct Measurement: Equatable {
        var height: CGFloat
        var children: [UUID]
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Measurement.self) {
                Measurement(height: $0.size.height, children: children)
            } action: { updated in
                let structuralChange = measured.map { $0.children != updated.children } == true
                withAnimation(structuralChange ? animation : nil) {
                    measured = updated
                }
            }
            .modifier(InterpolatedHeight(height: measured?.height ?? 0))
    }

    private struct InterpolatedHeight: AnimatableModifier {
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

/// List does not reliably run insertion transitions inside an existing row.
/// Give the new child's opacity its own transaction; removal still uses transition.
struct SidebarChildAppearance: ViewModifier {
    let visible: Bool
    let animation: Animation?
    let reveal: () -> Void

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .onChange(of: visible, initial: true) { _, visible in
                // A child can return before its removal transition completes;
                // that retained view does not receive another onAppear.
                guard !visible else { return }
                withAnimation(animation, reveal)
            }
    }
}
