import UIKit

/// The bubble fill. It draws through a nine-slice mask, so the fill, corners and tail follow the
/// view's frame inside any UIView animation, on the same clock as every other node.
final class MessageBubbleNodeView: UIView {
  private let fill = MessageBubbleFillView()
  private var highlightFill: MessageBubbleFillView?
  private(set) var side: MessageBubbleTailSide = .none
  private var fillColor: UIColor = .clear
  private var lighting: (top: CGFloat, bottom: CGFloat)?
  private var lightingVector: (startY: CGFloat, endY: CGFloat) = (0, 1)

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    fill.isUserInteractionEnabled = false
    addSubview(fill)
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MessageBubbleNodeView, _: UITraitCollection) in
      view.updateColors()
    }
    // The mask is rendered at the display scale; a view configured before joining a window
    // re-renders it once the real scale is known.
    registerForTraitChanges([UITraitDisplayScale.self]) { (view: MessageBubbleNodeView, _: UITraitCollection) in
      view.fill.configure(side: view.side, scale: view.maskScale)
      view.highlightFill?.configure(side: view.side, scale: view.maskScale)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(side: MessageBubbleTailSide, color: UIColor, lighting: (top: CGFloat, bottom: CGFloat)?) {
    self.side = side
    fillColor = color
    self.lighting = lighting
    fill.configure(side: side, scale: maskScale)
    highlightFill?.configure(side: side, scale: maskScale)
    updateColors()
  }

  private var maskScale: CGFloat {
    traitCollection.displayScale > 0 ? traitCollection.displayScale : UITraitCollection.current.displayScale
  }

  /// Sizes the fill to the current bounds now, so a caller's animation block covers it.
  func layoutFill() {
    for view in [fill, highlightFill].compactMap(\.self) {
      view.frame = bounds
      view.layoutIfNeeded()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutFill()
  }

  func visiblePath() -> UIBezierPath {
    MessageBubbleGeometry.path(in: bounds, side: side)
  }

  /// Positions the continuous lighting gradient for where the bubble sits in the viewport.
  func updateLightingVector(startY: CGFloat, endY: CGFloat) {
    guard lighting != nil else { return }
    guard abs(lightingVector.startY - startY) > 0.0001 || abs(lightingVector.endY - endY) > 0.0001 else { return }
    lightingVector = (startY, endY)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.gradient.startPoint = CGPoint(x: 0.5, y: startY)
    fill.gradient.endPoint = CGPoint(x: 0.5, y: endY)
    CATransaction.commit()
  }

  func highlight(color: UIColor, fadeIn: TimeInterval, hold: TimeInterval, fadeOut: TimeInterval = 0.5) {
    let overlay: MessageBubbleFillView
    if let highlightFill {
      overlay = highlightFill
    } else {
      overlay = MessageBubbleFillView()
      overlay.isUserInteractionEnabled = false
      overlay.layer.opacity = 0
      addSubview(overlay)
      highlightFill = overlay
    }
    overlay.configure(side: side, scale: maskScale)
    overlay.frame = bounds
    overlay.layoutIfNeeded()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let resolved = color.resolvedColor(with: traitCollection).cgColor
    overlay.gradient.colors = [resolved, resolved]
    CATransaction.commit()

    let duration = fadeIn + hold + fadeOut
    guard duration > 0 else { return }
    let pulse = CAKeyframeAnimation(keyPath: "opacity")
    pulse.values = [fadeIn > 0 ? 0 : 1, 1, 1, 0]
    pulse.keyTimes = [0, fadeIn / duration, (fadeIn + hold) / duration, 1].map { NSNumber(value: $0) }
    pulse.duration = duration
    overlay.layer.add(pulse, forKey: "messageHighlight")
  }

  func clearHighlight() {
    highlightFill?.layer.removeAnimation(forKey: "messageHighlight")
  }

  private func updateColors() {
    let color = fillColor.resolvedColor(with: traitCollection)
    let top = color.mixedWithWhite(alpha: lighting?.top ?? 0)
    let bottom = color.mixedWithWhite(alpha: lighting?.bottom ?? 0)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.gradient.colors = [top.cgColor, bottom.cgColor]
    fill.isHidden = color.cgColor.alpha <= 0.01
    CATransaction.commit()
  }
}
