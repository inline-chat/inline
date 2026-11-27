import AppKit
import InlineUI

class BasicView: NSView {
  // MARK: - Properties

  var backgroundColor: NSColor? {
    didSet { configureBackground() }
  }

  var borderColor: NSColor? {
    didSet { configureBorder() }
  }

  var borderWidth: CGFloat = 0 {
    didSet { configureBorder() }
  }

  var cornerRadius: CGFloat = 0 {
    didSet { configureCornerRadius() }
  }

  override var wantsUpdateLayer: Bool { true }

  // MARK: - Lifecycle

  init() {
    super.init(frame: .zero)
    configureView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Methods

  override func updateLayer() {
    super.updateLayer()
    configureBackground()
    configureBorder()
    configureCornerRadius()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    configureBackground()
    configureBorder()
  }

  private func configureView() {
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }

  private func configureBackground() {
    guard let layer else { return }
    layer.backgroundColor = backgroundColor?.resolvedColor(with: effectiveAppearance).cgColor
  }

  private func configureBorder() {
    guard let layer else { return }
    layer.borderColor = borderColor?.resolvedColor(with: effectiveAppearance).cgColor
    layer.borderWidth = borderWidth
  }

  /// The radius applied to the layer; subclasses can clamp it to their bounds.
  var renderedCornerRadius: CGFloat {
    cornerRadius
  }

  fileprivate func configureCornerRadius() {
    guard let layer else { return }
    layer.cornerRadius = renderedCornerRadius
  }
}

private final class MessageBubbleLightingLayer: CAGradientLayer {
  private var lastStartY: CGFloat?
  private var lastEndY: CGFloat?

  override init() {
    super.init()
    type = .axial
    locations = [0, 1]
    isHidden = true
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  func configure(topAlpha: CGFloat, bottomAlpha: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    colors = [
      NSColor.white.withAlphaComponent(topAlpha).cgColor,
      NSColor.white.withAlphaComponent(bottomAlpha).cgColor,
    ]
    CATransaction.commit()
  }

  func updateWindowVector(startY: CGFloat, endY: CGFloat) {
    guard startY.isFinite, endY.isFinite, endY > startY else {
      clearWindowVector()
      return
    }
    guard lastStartY != startY || lastEndY != endY || isHidden else { return }

    lastStartY = startY
    lastEndY = endY
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Window sampling uses a top-origin Y axis, while CAGradientLayer's local
    // unit coordinates are bottom-origin on macOS.
    startPoint = CGPoint(x: 0.5, y: 1 - startY)
    endPoint = CGPoint(x: 0.5, y: 1 - endY)
    isHidden = false
    CATransaction.commit()
  }

  func clearWindowVector() {
    guard !isHidden || lastStartY != nil || lastEndY != nil else { return }
    lastStartY = nil
    lastEndY = nil
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    isHidden = true
    CATransaction.commit()
  }
}

final class MessageBubbleBackgroundView: BasicView {
  private let lightingLayer = MessageBubbleLightingLayer()

  override init() {
    super.init()
    layer?.addSublayer(lightingLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Core Animation does not clamp a corner radius larger than half the height; it draws
  // overlapping arcs with spikes on the sides. Bubbles can be shorter than 2r with small
  // fonts, so clamp the same way the tail geometry does.
  override var renderedCornerRadius: CGFloat {
    MessageBubbleTailGeometry.effectiveRadius(cornerRadius: cornerRadius, size: bounds.size)
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    configureCornerRadius()
    lightingLayer.frame = bounds
    lightingLayer.cornerRadius = renderedCornerRadius
    lightingLayer.masksToBounds = true
    CATransaction.commit()
  }

  func configureContinuousGradient(topAlpha: CGFloat, bottomAlpha: CGFloat) {
    lightingLayer.configure(topAlpha: topAlpha, bottomAlpha: bottomAlpha)
  }

  func updateContinuousGradient(startY: CGFloat, endY: CGFloat) {
    lightingLayer.updateWindowVector(startY: startY, endY: endY)
  }

  func clearContinuousGradient() {
    lightingLayer.clearWindowVector()
  }
}

final class MessageBubbleTailView: NSView {
  enum Side {
    case none
    case leading
    case trailing
  }

  /// The largest corner radius the tail is drawn for. The view is sized for it and
  /// pinned to the bubble's bottom corner; smaller bubbles draw a proportionally
  /// smaller tail inside the same frame.
  static let maxCornerRadius: CGFloat = Theme.messageBubbleCornerRadius

  /// Distance the view's frame extends past the bubble's bottom edge, so the
  /// antialiased tip is never clipped.
  static let bottomOverhang: CGFloat = 1

  static var size: CGSize {
    CGSize(
      width: maxCornerRadius + MessageBubbleTailGeometry.exposedWidth(radius: maxCornerRadius) + 1,
      height: maxCornerRadius + bottomOverhang
    )
  }

  /// How far the view's frame extends under the bubble from its side edge.
  static var bubbleOverlap: CGFloat {
    maxCornerRadius
  }

  /// Bubble body size, used to match the radius Core Animation renders for the body.
  var bubbleSize: CGSize = .zero {
    didSet {
      guard bubbleSize != oldValue else { return }
      updateLayerGeometry()
    }
  }

  private var cornerRadius: CGFloat {
    MessageBubbleTailGeometry.effectiveRadius(cornerRadius: Self.maxCornerRadius, size: bubbleSize)
  }

  private(set) var side: Side = .none

  private var fillColor: NSColor = .clear
  /// The tail's fill. Core Animation draws it from the path, so the view itself draws
  /// nothing and has no backing store to fill when rows are configured or appear.
  private let fillLayer = CAShapeLayer()
  private let lightingLayer = MessageBubbleLightingLayer()
  private let lightingMaskLayer = CAShapeLayer()
  /// What the fill and mask paths were built for.
  private var appliedGeometry: (side: Side, radius: CGFloat, bounds: CGRect)?
  /// What the fill color was resolved from.
  private var appliedFill: (color: NSColor, appearance: NSAppearance.Name)?
  private var fillAlpha: CGFloat = 0

  override var isFlipped: Bool { true }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.masksToBounds = false
    fillLayer.fillColor = nil
    layer?.addSublayer(fillLayer)
    lightingLayer.mask = lightingMaskLayer
    layer?.addSublayer(lightingLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func layout() {
    super.layout()
    updateLayerGeometry()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateFill()
  }

  func configure(side: Side, color: NSColor, animated: Bool = false) {
    guard self.side != side || !fillColor.isEqual(color) else { return }
    let oldSide = self.side
    let oldColor = fillColor
    if animated, oldSide != side {
      animateRemovedTail(side: oldSide, color: oldColor)
    }

    self.side = side
    fillColor = color
    updateFill()
    updateLayerGeometry()
  }

  func configureContinuousGradient(topAlpha: CGFloat, bottomAlpha: CGFloat) {
    lightingLayer.configure(topAlpha: topAlpha, bottomAlpha: bottomAlpha)
  }

  func updateContinuousGradient(startY: CGFloat, endY: CGFloat) {
    guard side != .none else {
      lightingLayer.clearWindowVector()
      return
    }
    lightingLayer.updateWindowVector(startY: startY, endY: endY)
  }

  func clearContinuousGradient() {
    lightingLayer.clearWindowVector()
  }

  /// Resolves the fill color for the current appearance. Re-parenting a row reports an
  /// appearance change without one, so an unchanged color and appearance are skipped.
  private func updateFill() {
    let appearance = effectiveAppearance.name
    if appliedFill?.color.isEqual(fillColor) != true || appliedFill?.appearance != appearance {
      appliedFill = (fillColor, appearance)
      let resolved = fillColor.resolvedColor(with: effectiveAppearance)
      fillAlpha = resolved.alphaComponent
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      fillLayer.fillColor = resolved.cgColor
      CATransaction.commit()
    }
    let hidden = side == .none || fillAlpha <= 0.01
    if isHidden != hidden { isHidden = hidden }
  }

  /// Builds the tail path when the side, radius or bounds change, for the fill and the lighting mask.
  private func updateLayerGeometry() {
    let radius = cornerRadius
    if let appliedGeometry, appliedGeometry.side == side, appliedGeometry.radius == radius,
       appliedGeometry.bounds == bounds
    {
      return
    }
    appliedGeometry = (side, radius, bounds)
    let path = Self.path(for: side, radius: radius, in: bounds)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fillLayer.frame = bounds
    fillLayer.path = path
    lightingLayer.frame = bounds
    lightingMaskLayer.frame = bounds
    lightingMaskLayer.path = path
    CATransaction.commit()
  }

  private func animateRemovedTail(side: Side, color: NSColor) {
    guard side != .none, !bounds.isEmpty, color.resolvedColor(with: effectiveAppearance).alphaComponent > 0.01,
          let superview
    else {
      return
    }

    let fadeView = MessageBubbleTailFadeView(side: side, radius: cornerRadius, color: color)
    fadeView.frame = frame
    fadeView.alphaValue = 1
    superview.addSubview(fadeView, positioned: .above, relativeTo: self)

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      fadeView.animator().alphaValue = 0
    } completionHandler: {
      fadeView.removeFromSuperview()
    }
  }

  /// Tail path in this view's flipped bounds. The bubble's bottom corner sits
  /// `maxCornerRadius` in from the edge facing the bubble, `bottomOverhang` above the bottom.
  fileprivate static func path(for side: Side, radius: CGFloat, in rect: CGRect) -> CGPath? {
    let bottom = rect.maxY - bottomOverhang
    switch side {
    case .none:
      return nil
    case .leading:
      return MessageBubbleTailGeometry.tailPath(
        corner: CGPoint(x: rect.maxX - maxCornerRadius, y: bottom),
        radius: radius,
        side: .leading
      )
    case .trailing:
      return MessageBubbleTailGeometry.tailPath(
        corner: CGPoint(x: rect.minX + maxCornerRadius, y: bottom),
        radius: radius,
        side: .trailing
      )
    }
  }
}

private final class MessageBubbleTailFadeView: NSView {
  private let side: MessageBubbleTailView.Side
  private let radius: CGFloat
  private let fillColor: NSColor

  override var isFlipped: Bool { true }

  init(side: MessageBubbleTailView.Side, radius: CGFloat, color: NSColor) {
    self.side = side
    self.radius = radius
    fillColor = color
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let path = MessageBubbleTailView.path(for: side, radius: radius, in: bounds) else { return }
    fillColor.resolvedColor(with: effectiveAppearance).setFill()
    NSBezierPath(cgPath: path).fill()
  }
}
