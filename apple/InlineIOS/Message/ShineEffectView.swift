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
    // Ensure the view clips to bounds
    clipsToBounds = true

    // Create shine layer
    if let shineImage = UIImage(named: "shine") {
      shineLayer.contents = shineImage.cgImage
    }
    shineLayer.contentsGravity = .resizeAspectFill
    shineLayer.opacity = 0.4 // Add some transparency to the shine

    // Create mask layer
    maskLayer.backgroundColor = UIColor.black.cgColor

    // Add layers
    layer.addSublayer(shineLayer)
    shineLayer.mask = maskLayer
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    // Update layer frames
    shineLayer.frame = bounds
    maskLayer.frame = bounds

    // Update animation if needed
    if animation != nil {
      updateAnimation()
    }
  }

  func startAnimation() {
    // Remove existing animation if any
    stopAnimation()

    // Create new animation
    let animation = CABasicAnimation(keyPath: "position.x")
    animation.fromValue = -bounds.width * 0.5
    animation.toValue = bounds.width * 1.5
    animation.duration = 2.0
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

    // Add animation to shine layer
    shineLayer.add(animation, forKey: "shine")
    self.animation = animation
  }

  func stopAnimation() {
    shineLayer.removeAnimation(forKey: "shine")
    animation = nil
  }

  private func updateAnimation() {
    guard let animation else { return }

    // Update animation values for new bounds
    animation.fromValue = -bounds.width
    animation.toValue = bounds.width * 2

    // Re-add animation with new values
    shineLayer.add(animation, forKey: "shine")
  }
}
