import SwiftUI
import UIKit

/// Keeps grouped resting corners while rounding the exposed corners during a native swipe.
struct SessionRowBackground: UIViewRepresentable {
    let isFirst: Bool
    let isLast: Bool

    func makeUIView(context: Context) -> SessionRowBackgroundView {
        SessionRowBackgroundView(frame: .zero)
    }

    func updateUIView(_ view: SessionRowBackgroundView, context: Context) {
        view.configure(isFirst: isFirst, isLast: isLast)
    }

    static func dismantleUIView(_ view: SessionRowBackgroundView, coordinator: ()) {
        view.stopTracking()
    }
}

final class SessionRowBackgroundView: UIView {
    private let fill = CAShapeLayer()
    private var displayLink: CADisplayLink?
    private var isFirst = false
    private var isLast = false
    private var drawnBounds = CGRect.null
    private var drawnTopRadius: CGFloat = -1
    private var drawnBottomRadius: CGFloat = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        layer.addSublayer(fill)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self,
                                 UITraitUserInterfaceLevel.self]) { (view: SessionRowBackgroundView, _) in
            view.drawnBounds = .null
            view.updateShape()
        }
    }

    required init?(coder: NSCoder) { nil }

    func configure(isFirst: Bool, isLast: Bool) {
        self.isFirst = isFirst
        self.isLast = isLast
        updateShape()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateShape()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        stopTracking()
        guard window != nil else { return }
        // Only attached row backgrounds track frames, including during gesture tracking.
        let link = CADisplayLink(target: DisplayLinkTarget(view: self), selector: #selector(DisplayLinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        drawnBounds = .null
        updateShape()
    }

    func stopTracking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    fileprivate func updateShape() {
        let groupedRadius: CGFloat
        if #available(iOS 26.0, *) { groupedRadius = 26 }
        else { groupedRadius = 10 }
        let radius = min(groupedRadius, min(bounds.width, bounds.height) / 2)
        // No gesture threshold or independent animation: even the first point of
        // movement rounds a missing corner, and cancellation follows the content home.
        let exposedRadius = min(radius, horizontalDisplacement())
        let topRadius = isFirst ? radius : exposedRadius
        let bottomRadius = isLast ? radius : exposedRadius
        guard bounds != drawnBounds || topRadius != drawnTopRadius || bottomRadius != drawnBottomRadius else { return }
        drawnBounds = bounds
        drawnTopRadius = topRadius
        drawnBottomRadius = bottomRadius

        let rect = CGRect(origin: .zero, size: bounds.size)
        let shape = UnevenRoundedRectangle(topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius,
                                           bottomTrailingRadius: bottomRadius, topTrailingRadius: topRadius,
                                           style: .continuous)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        fill.fillColor = UIColor.secondarySystemGroupedBackground.resolvedColor(with: traitCollection).cgColor
        fill.path = shape.path(in: rect).cgPath
        CATransaction.commit()
    }

    private func horizontalDisplacement() -> CGFloat {
        guard let cell = ancestor(ofType: UICollectionViewCell.self),
              let collection = ancestor(ofType: UICollectionView.self),
              let indexPath = collection.indexPath(for: cell),
              let attributes = collection.layoutAttributesForItem(at: indexPath) else { return 0 }

        let content = cell.contentView
        let frame: CGRect
        if let contentLayer = content.layer.presentation(), let collectionLayer = collection.layer.presentation() {
            // Convert through the presentation tree so interactive movement and the
            // animated return are measured, not the animation's model-layer endpoint.
            frame = contentLayer.convert(contentLayer.bounds, to: collectionLayer)
        } else {
            frame = content.convert(content.bounds, to: collection)
        }
        // Both edges also detect native swipe layouts that shrink the content view.
        return max(abs(frame.minX - attributes.frame.minX), abs(frame.maxX - attributes.frame.maxX))
    }

    private func ancestor<View: UIView>(ofType: View.Type) -> View? {
        var candidate = superview
        while let view = candidate {
            if let match = view as? View { return match }
            candidate = view.superview
        }
        return nil
    }
}

@MainActor
private final class DisplayLinkTarget: NSObject {
    weak var view: SessionRowBackgroundView?

    init(view: SessionRowBackgroundView) { self.view = view }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else {
            link.invalidate()
            return
        }
        view.updateShape()
    }
}
