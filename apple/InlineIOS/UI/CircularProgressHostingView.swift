import UIKit

final class CircularProgressHostingView: UIView {
  private enum Constants {
    static let lineWidth: CGFloat = 2.6
    static let minVisibleProgress: CGFloat = 0.06
    static let rotationDuration: CFTimeInterval = 1.5
    static let ringInset: CGFloat = 1
    static let rotationKey = "circularProgressRotation"
  }

  private let progressLayer = CAShapeLayer()
  private var displayedProgress: CGFloat = Constants.minVisibleProgress

  override init(frame: CGRect) {
    super.init(frame: frame)

    isUserInteractionEnabled = false
    backgroundColor = .clear

    progressLayer.fillColor = UIColor.clear.cgColor
    progressLayer.strokeColor = UIColor.white.cgColor
    progressLayer.lineWidth = Constants.lineWidth
    progressLayer.lineCap = .round
    progressLayer.strokeStart = 0
    progressLayer.strokeEnd = displayedProgress
    layer.addSublayer(progressLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHidden: Bool {
    didSet {
      updateAnimations()
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateAnimations()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updatePath()
  }

  func setProgress(_ progress: Double) {
    let clamped = CGFloat(min(max(progress, 0), 1))

    if clamped <= 0.0001 {
      displayedProgress = Constants.minVisibleProgress
    } else {
      let adjusted = max(Constants.minVisibleProgress, clamped)
      // Keep progress visually stable and one-directional.
      displayedProgress = max(displayedProgress, adjusted)
    }

    CATransaction.begin()
    CATransaction.setAnimationDuration(0.12)
    CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
    progressLayer.strokeEnd = displayedProgress
    CATransaction.commit()
  }

  private func updatePath() {
    progressLayer.frame = bounds

    let diameter = min(bounds.width, bounds.height)
    let radius = max(0, (diameter / 2) - (Constants.lineWidth / 2) - Constants.ringInset)
    let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
    progressLayer.path = UIBezierPath(
      arcCenter: center,
      radius: radius,
      startAngle: -.pi / 2,
      endAngle: (CGFloat.pi * 3) / 2,
      clockwise: true
    ).cgPath
  }

  private func updateAnimations() {
    updateRotationAnimation()
  }

  private func updateRotationAnimation() {
    guard !isHidden, window != nil else {
      progressLayer.removeAnimation(forKey: Constants.rotationKey)
      return
    }

    guard progressLayer.animation(forKey: Constants.rotationKey) == nil else { return }

    let animation = CABasicAnimation(keyPath: "transform.rotation.z")
    animation.fromValue = 0
    animation.toValue = CGFloat.pi * 2
    animation.duration = Constants.rotationDuration
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    progressLayer.add(animation, forKey: Constants.rotationKey)
  }

}
