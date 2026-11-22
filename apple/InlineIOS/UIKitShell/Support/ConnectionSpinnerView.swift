import InlineCompatUI
import UIKit

/// Rotating arc shown in the home toolbar while realtime connects.
final class ConnectionSpinnerView: UIView {
  private static let animationKey = "inline.connection-spinner.rotation"
  private static let rotationDuration: CFTimeInterval = 0.65

  private let trackLayer = CAShapeLayer()
  private let arcLayer = CAShapeLayer()
  private var lineWidth: CGFloat = 2.25

  override init(frame: CGRect) {
    super.init(frame: frame)

    backgroundColor = .clear
    isOpaque = false

    trackLayer.fillColor = UIColor.clear.cgColor
    arcLayer.fillColor = UIColor.clear.cgColor
    arcLayer.lineCap = .round
    arcLayer.strokeStart = 0
    arcLayer.strokeEnd = 0.72

    layer.addSublayer(trackLayer)
    layer.addSublayer(arcLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    startAnimatingIfNeeded()
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let layerBounds = bounds
    let circleBounds = layerBounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
    let circlePath = UIBezierPath(ovalIn: circleBounds).cgPath

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trackLayer.frame = layerBounds
    trackLayer.path = circlePath
    arcLayer.frame = layerBounds
    arcLayer.path = circlePath
    CATransaction.commit()

    startAnimatingIfNeeded()
  }

  func update(color: UIColor, lineWidth: CGFloat) {
    let resolvedColor = color.resolvedColor(with: traitCollection)
    self.lineWidth = lineWidth

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    trackLayer.strokeColor = resolvedColor.withAlphaComponent(0.14).cgColor
    trackLayer.lineWidth = lineWidth
    arcLayer.strokeColor = resolvedColor.cgColor
    arcLayer.lineWidth = lineWidth
    CATransaction.commit()

    setNeedsLayout()
    startAnimatingIfNeeded()
  }

  private func startAnimatingIfNeeded() {
    guard window != nil else { return }
    guard arcLayer.animation(forKey: Self.animationKey) == nil else { return }

    let layerTime = arcLayer.convertTime(CACurrentMediaTime(), from: nil)
    let animation = CABasicAnimation(keyPath: "transform.rotation.z")
    animation.fromValue = 0
    animation.toValue = CGFloat.pi * 2
    animation.duration = Self.rotationDuration
    animation.repeatCount = .infinity
    // Align every recreated toolbar host to one continuous phase instead of restarting at zero.
    animation.beginTime = layerTime - layerTime.truncatingRemainder(dividingBy: Self.rotationDuration)
    animation.isRemovedOnCompletion = false
    arcLayer.add(animation, forKey: Self.animationKey)
  }
}

extension ConnectionSpinnerView {
  /// Spinner sized for a bar button item, following the label color.
  static func toolbarItem() -> ConnectionSpinnerView {
    let view = ConnectionSpinnerView(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
    view.isUserInteractionEnabled = false
    view.update(color: .label, lineWidth: 2.25)
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      view.widthAnchor.constraint(equalToConstant: 18),
      view.heightAnchor.constraint(equalToConstant: 18),
    ])
    view.compatRegisterForTraitChangesIfAvailable()
    return view
  }

  fileprivate func compatRegisterForTraitChangesIfAvailable() {
    compatRegisterForTraitChanges([.userInterfaceStyle]) { (view: ConnectionSpinnerView, _: UITraitCollection) in
      view.update(color: .label, lineWidth: 2.25)
    }
  }
}
