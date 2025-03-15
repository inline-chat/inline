// ScrollToBottomButton.swift
import AppKit

final class ScrollToBottomButton: NSControl {
  private let buttonSize: CGFloat = Theme.scrollButtonSize
  private let circleLayer = CAShapeLayer()
  private let symbolLayer = CALayer()

  private var isVisible = false

  var onClick: (() -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    setupLayers()
    setupTrackingArea()

    wantsLayer = true
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    symbolLayer.contentsScale = window?.backingScaleFactor ?? 1.0
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Add to ScrollToBottomButton:
  override func accessibilityLabel() -> String? {
    NSLocalizedString("Scroll to bottom", comment: "Accessibility label")
  }

  private func setupLayers() {
    wantsLayer = true
    layer?.masksToBounds = false
    layer?.opacity = 0

    // Circular background
    let circlePath = CGMutablePath()
    circlePath.addEllipse(in: CGRect(x: 0, y: 0, width: buttonSize, height: buttonSize))

    circleLayer.path = circlePath
    circleLayer.fillColor = NSColor.controlBackgroundColor.cgColor
    circleLayer.shadowColor = NSColor.black.cgColor
    circleLayer.shadowOpacity = 0.15
    circleLayer.shadowOffset = CGSize(width: 0, height: -1)
    circleLayer.shadowRadius = 2
    circleLayer.contentsGravity = .center

    // Set anchor point to center (0.5, 0.5)
    circleLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

    layer?.addSublayer(circleLayer)

    // Chevron symbol
    let symbolSize: CGFloat = 14
    let symbolImage = NSImage(
      systemSymbolName: "chevron.down",
      accessibilityDescription: "Scroll to bottom"
    )?
      .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    symbolLayer.contents = symbolImage
    symbolLayer.opacity = 0.5
    symbolLayer.contentsGravity = .resizeAspect
    // Set anchor point to center
    symbolLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    symbolLayer.frame = CGRect(
      x: (buttonSize - symbolSize) / 2,
      y: (buttonSize - symbolSize) / 2,
      width: symbolSize,
      height: symbolSize
    )
    layer?.addSublayer(symbolLayer)
  }

  private func setupTrackingArea() {
    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseEnteredAndExited],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
  }

  override func mouseDown(with event: NSEvent) {
    animateClick(pressed: true)
  }

  override func mouseUp(with event: NSEvent) {
    animateClick(pressed: false)
    if isVisible {
      onClick?()
    }
  }

  private func animateClick(pressed: Bool) {
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.1)
    // Fade
    layer?.opacity = pressed ? 0.9 : 1.0
    CATransaction.commit()
  }

  func setVisibility(_ visible: Bool) {
    let hidden = !visible
    let targetOpacity: Float = hidden ? 0 : 1
    guard layer?.opacity != targetOpacity else { return }

    isVisible = visible

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      context.allowsImplicitAnimation = true
      layer?.opacity = targetOpacity
    }
  }
}
