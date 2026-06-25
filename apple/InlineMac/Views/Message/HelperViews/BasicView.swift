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

  static let size = CGSize(width: 16, height: 15)
  static let bubbleOverlap: CGFloat = 9
  static let bottomOffset: CGFloat = 0

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
    let width = rect.width
    let height = rect.height
    let sideEdge = width
    let visibleJoinX = max(0, width - Self.bubbleOverlap)
    let footX: CGFloat = 1.1
    let footY = rect.maxY - 1.2
    let lowerJoinX = max(0, visibleJoinX - 0.4)
    let lowerControlX = max(0, lowerJoinX - 0.8)
    let lowerJoinY = rect.maxY - 0.7
    let bottomJoin = rect.maxY - 4.4

    func x(_ value: CGFloat) -> CGFloat {
      switch side {
      case .none, .leading:
        return rect.minX + value
      case .trailing:
        return rect.maxX - value
      }
    }

    let path = NSBezierPath()
    path.move(to: CGPoint(x: x(sideEdge), y: rect.minY + 1.0))
    path.curve(
      to: CGPoint(x: x(visibleJoinX + 1.1), y: rect.minY + height * 0.48),
      controlPoint1: CGPoint(x: x(sideEdge), y: rect.minY + height * 0.26),
      controlPoint2: CGPoint(x: x(visibleJoinX + 3.8), y: rect.minY + height * 0.42)
    )
    path.curve(
      to: CGPoint(x: x(footX + 1.4), y: footY - 0.65),
      controlPoint1: CGPoint(x: x(visibleJoinX + 0.2), y: rect.minY + height * 0.68),
      controlPoint2: CGPoint(x: x(footX + 2.6), y: footY - 1.15)
    )
    path.curve(
      to: CGPoint(x: x(footX), y: footY),
      controlPoint1: CGPoint(x: x(footX + 0.8), y: footY - 0.15),
      controlPoint2: CGPoint(x: x(footX + 0.25), y: footY)
    )
    path.curve(
      to: CGPoint(x: x(lowerJoinX), y: lowerJoinY),
      controlPoint1: CGPoint(x: x(footX + 0.8), y: rect.maxY + 0.4),
      controlPoint2: CGPoint(x: x(lowerControlX), y: lowerJoinY + 0.15)
    )
    path.curve(
      to: CGPoint(x: x(sideEdge), y: bottomJoin),
      controlPoint1: CGPoint(x: x(visibleJoinX + 0.8), y: lowerJoinY - 0.15),
      controlPoint2: CGPoint(x: x(sideEdge - 1.2), y: bottomJoin + 0.25)
    )
    path.close()
    return path
  }
}
