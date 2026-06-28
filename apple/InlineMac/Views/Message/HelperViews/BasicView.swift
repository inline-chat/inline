import AppKit

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

  private func configureCornerRadius() {
    guard let layer else { return }
    layer.cornerRadius = cornerRadius
  }
}

final class MessageBubbleTailView: NSView {
  enum Side {
    case none
    case leading
    case trailing
  }

  // Cropped from the trailing-side full-bubble SVG. `sourceBubbleEdgeX` is the
  // bubble edge the visible tail tucks under before mirroring for leading tails.
  private static let sourceSize = CGSize(width: 37, height: 52.4)
  private static let sourceBubbleEdgeX: CGFloat = 19.5183
  private static let sourceTailBottomY: CGFloat = 51.2853
  private static let tailDrawScale: CGFloat = 14 / sourceTailBottomY

  private static var exposedTailWidth: CGFloat {
    (sourceSize.width - sourceBubbleEdgeX) * tailDrawScale
  }

  static var size: CGSize {
    CGSize(
      width: sourceSize.width * tailDrawScale,
      height: sourceSize.height * tailDrawScale
    )
  }

  static var bubbleOverlap: CGFloat {
    size.width - exposedTailWidth
  }

  static var bottomOffset: CGFloat {
    size.height - sourceTailBottomY * tailDrawScale
  }

  private(set) var side: Side = .none

  private var fillColor: NSColor = .clear

  override var isFlipped: Bool { true }

  init() {
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
    guard side != .none else { return }

    resolvedFillColor.setFill()
    Self.path(for: side, in: bounds).fill()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateVisibility()
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
    updateVisibility()
  }

  private func updateVisibility() {
    isHidden = side == .none || resolvedFillColor.alphaComponent <= 0.01
    needsDisplay = true
  }

  private var resolvedFillColor: NSColor {
    fillColor.resolvedColor(with: effectiveAppearance)
  }

  private func animateRemovedTail(side: Side, color: NSColor) {
    guard side != .none, !bounds.isEmpty, color.resolvedColor(with: effectiveAppearance).alphaComponent > 0.01,
          let superview
    else {
      return
    }

    let fadeView = MessageBubbleTailFadeView(side: side, color: color)
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

  fileprivate static func path(for side: Side, in rect: CGRect) -> NSBezierPath {
    let scaleX = rect.width / Self.sourceSize.width
    let scaleY = rect.height / Self.sourceSize.height

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      let resolvedX: CGFloat = switch side {
      case .leading:
        rect.maxX - x * scaleX
      case .none, .trailing:
        rect.minX + x * scaleX
      }
      return CGPoint(x: resolvedX, y: rect.minY + y * scaleY)
    }

    let path = NSBezierPath()
    path.move(to: point(19.4761, 6.9846))
    path.curve(
      to: point(19.5183, 0),
      controlPoint1: point(19.5041, 6.3302),
      controlPoint2: point(19.5183, 0.6611)
    )
    path.line(to: point(0, 0))
    path.line(to: point(0, 39.8152))
    path.curve(
      to: point(36.1476, 50.9938),
      controlPoint1: point(8.3867, 48.2023),
      controlPoint2: point(22.1067, 52.3205)
    )
    path.curve(
      to: point(36.5785, 50.7275),
      controlPoint1: point(36.3267, 50.9769),
      controlPoint2: point(36.4868, 50.878)
    )
    path.curve(
      to: point(36.3805, 49.9764),
      controlPoint1: point(36.7373, 50.4669),
      controlPoint2: point(36.6487, 50.1307)
    )
    path.line(to: point(35.3668, 49.3821))
    path.curve(
      to: point(22.3321, 37.0489),
      controlPoint1: point(28.7234, 45.413),
      controlPoint2: point(24.3785, 41.3021)
    )
    path.curve(
      to: point(19.4761, 6.9846),
      controlPoint1: point(20.1278, 32.4675),
      controlPoint2: point(19.1757, 22.4468)
    )
    path.close()
    return path
  }
}

private final class MessageBubbleTailFadeView: NSView {
  private let side: MessageBubbleTailView.Side
  private let fillColor: NSColor

  override var isFlipped: Bool { true }

  init(side: MessageBubbleTailView.Side, color: NSColor) {
    self.side = side
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
    fillColor.resolvedColor(with: effectiveAppearance).setFill()
    MessageBubbleTailView.path(for: side, in: bounds).fill()
  }
}
