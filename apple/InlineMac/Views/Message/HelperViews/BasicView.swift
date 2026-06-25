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

  private func configureView() {
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }

  private func configureBackground() {
    guard let layer else { return }
    layer.backgroundColor = backgroundColor?.cgColor
  }

  private func configureBorder() {
    guard let layer else { return }
    layer.borderColor = borderColor?.cgColor
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

  private static let sourceSize = CGSize(width: 42, height: 36)
  private static let sourceTailBottomY: CGFloat = 35
  private static let tailDrawScale: CGFloat = 0.80
  private static let exposedTailWidth: CGFloat = 4.2

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
    path(in: bounds).fill()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateVisibility()
  }

  func configure(side: Side, color: NSColor) {
    guard self.side != side || !fillColor.isEqual(color) else { return }
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

  private func path(in rect: CGRect) -> NSBezierPath {
    let scaleX = rect.width / Self.sourceSize.width
    let scaleY = rect.height / Self.sourceSize.height

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      let resolvedX: CGFloat = switch side {
      case .none, .leading:
        rect.minX + x * scaleX
      case .trailing:
        rect.maxX - x * scaleX
      }
      return CGPoint(x: resolvedX, y: rect.minY + y * scaleY)
    }

    let path = NSBezierPath()
    path.move(to: point(6, 17.5))
    path.curve(
      to: point(23.5, 0.2),
      controlPoint1: point(6, 7.9),
      controlPoint2: point(13.85, 0.2)
    )
    path.curve(
      to: point(40.8, 17.5),
      controlPoint1: point(33.05, 0.2),
      controlPoint2: point(40.8, 7.95)
    )
    path.curve(
      to: point(23.5, 34.8),
      controlPoint1: point(40.8, 27.05),
      controlPoint2: point(33.05, 34.8)
    )
    path.curve(
      to: point(12.4, 31.05),
      controlPoint1: point(19.3, 34.8),
      controlPoint2: point(15.45, 33.35)
    )
    path.curve(
      to: point(0.15, 35),
      controlPoint1: point(9.15, 34.75),
      controlPoint2: point(0.45, 35)
    )
    path.curve(
      to: point(6, 26.9),
      controlPoint1: point(5.8, 31.7),
      controlPoint2: point(6, 26.9)
    )
    path.close()
    return path
  }
}
