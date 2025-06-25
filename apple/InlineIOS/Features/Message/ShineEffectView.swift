import UIKit

class ShineEffectView: UIView {
  private let shineLayer = CALayer()
  private let maskLayer = CALayer()
  private var animation: CABasicAnimation?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    clipsToBounds = true

    if let shineImage = UIImage(named: "shine") {
      shineLayer.contents = shineImage.cgImage
    }
    shineLayer.contentsGravity = .resizeAspectFill
    shineLayer.opacity = 0.4

    maskLayer.backgroundColor = UIColor.black.cgColor

    layer.addSublayer(shineLayer)
    shineLayer.mask = maskLayer
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    shineLayer.frame = bounds
    maskLayer.frame = bounds

    if animation != nil {
      updateAnimation()
    }
  }

  func startAnimation() {
    stopAnimation()

    let animation = CABasicAnimation(keyPath: "position.x")
    animation.fromValue = -bounds.width * 0.5
    animation.toValue = bounds.width * 1.5
    animation.duration = 2.0
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

    shineLayer.add(animation, forKey: "shine")
    self.animation = animation
  }

  func stopAnimation() {
    shineLayer.removeAnimation(forKey: "shine")
    animation = nil
  }

  private func updateAnimation() {
    guard let animation else { return }

    animation.fromValue = -bounds.width
    animation.toValue = bounds.width * 2

    shineLayer.add(animation, forKey: "shine")
  }
}
