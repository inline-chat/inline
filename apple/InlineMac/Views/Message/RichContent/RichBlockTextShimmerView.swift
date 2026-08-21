import AppKit

final class RichBlockTextShimmerView: NSView {
  private let maskedContainer = CALayer()
  private let shine = CALayer()
  private let textMask = CALayer()
  private var isAnimating = false
  private var maskRevision: UInt64?
  private var maskSize = CGSize.zero
  private var maskScale: CGFloat = 0
  private var animationWidth: CGFloat = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = true
    shine.contents = NSImage(named: "shine")
    shine.contentsGravity = .resizeAspect
    shine.opacity = 0.68
    shine.transform = CATransform3DMakeRotation(15 * .pi / 180, 0, 0, 1)
    maskedContainer.mask = textMask
    maskedContainer.addSublayer(shine)
    layer?.addSublayer(maskedContainer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(color: NSColor) {
    if shine.contents == nil {
      shine.backgroundColor = color.withAlphaComponent(0.3).cgColor
    }
  }

  func updateMask(from surface: RichBlockTextSurface) {
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    guard maskRevision != surface.renderRevision || maskSize != bounds.size || maskScale != scale else {
      return
    }
    maskRevision = surface.renderRevision
    maskSize = bounds.size
    maskScale = scale
    textMask.contents = surface.renderedMaskImage()
    textMask.contentsScale = scale
    textMask.contentsGravity = .resize
  }

  func setAnimating(_ animate: Bool) {
    guard animate != isAnimating else { return }
    isAnimating = animate
    isHidden = !animate
    if animate {
      installAnimation()
    } else {
      shine.removeAnimation(forKey: "rich-text-shimmer")
      animationWidth = 0
    }
  }

  override func hitTest(_: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    maskedContainer.frame = bounds
    textMask.frame = bounds
    shine.bounds = CGRect(x: 0, y: 0, width: 120, height: bounds.height + 100)
    shine.position = CGPoint(x: -60, y: bounds.midY)
    CATransaction.commit()
    if isAnimating, animationWidth != bounds.width {
      installAnimation()
    }
  }

  private func installAnimation() {
    guard bounds.width > 0 else { return }
    animationWidth = bounds.width
    let animation = CABasicAnimation(keyPath: "position.x")
    animation.fromValue = -60
    animation.toValue = bounds.width + 60
    animation.duration = 2.25
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    shine.add(animation, forKey: "rich-text-shimmer")
  }
}
