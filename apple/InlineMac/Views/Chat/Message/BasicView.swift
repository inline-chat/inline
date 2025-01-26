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
