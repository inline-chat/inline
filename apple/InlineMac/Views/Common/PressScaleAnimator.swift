import AppKit

enum PressScaleAnimator {
  static let scale: CGFloat = 0.95

  static func prepare(_ view: NSView) {
    guard let layer = view.layer else { return }
    let center = CGPoint(x: 0.5, y: 0.5)
    guard layer.anchorPoint != center else { return }

    let frame = layer.frame
    layer.anchorPoint = center
    layer.frame = frame
  }

  static func setPressed(_ pressed: Bool, on view: NSView) {
    guard let layer = view.layer else { return }
    prepare(view)

    let target = pressed
      ? CATransform3DMakeScale(scale, scale, 1)
      : CATransform3DIdentity
    let from = layer.presentation()?.transform ?? layer.transform

    layer.removeAnimation(forKey: "inline.pressScale")
    layer.transform = target

    let animation = CABasicAnimation(keyPath: "transform")
    animation.fromValue = NSValue(caTransform3D: from)
    animation.toValue = NSValue(caTransform3D: target)
    animation.duration = pressed ? 0.08 : 0.14
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layer.add(animation, forKey: "inline.pressScale")
  }
}
