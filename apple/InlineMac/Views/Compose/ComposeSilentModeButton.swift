import AppKit

final class ComposeSilentModeButton: NSView {
  static let controlSize: CGFloat = Theme.composeButtonSize * 0.94

  private let size: CGFloat = ComposeSilentModeButton.controlSize
  private let iconView: NSImageView
  private var trackingArea: NSTrackingArea?
  private var isHovering = false

  var onClick: (() -> Void)?

  override init(frame frameRect: NSRect) {
    let configuration = NSImage.SymbolConfiguration(pointSize: ComposeSilentModeButton.controlSize * 0.58, weight: .semibold)
    let image = NSImage(systemSymbolName: "bell.slash", accessibilityDescription: "Disable send silently")?
      .withSymbolConfiguration(configuration)
    iconView = NSImageView(image: image ?? NSImage())
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentTintColor = .tertiaryLabelColor

    super.init(frame: frameRect)
    setupView()
  }

  convenience init() {
    self.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = size / 2
    layer?.masksToBounds = true

    addSubview(iconView)

    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    toolTip = "Send silently is enabled for this chat. Click to turn it off."
  }

  override func layout() {
    super.layout()
    layer?.cornerRadius = bounds.height / 2
  }

  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    onClick?()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let existingTrackingArea = trackingArea {
      removeTrackingArea(existingTrackingArea)
    }

    let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
    trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)

    if let trackingArea {
      addTrackingArea(trackingArea)
    }
  }

  override func mouseEntered(with event: NSEvent) {
    isHovering = true
    updateBackgroundColor()
  }

  override func mouseExited(with event: NSEvent) {
    isHovering = false
    updateBackgroundColor()
  }

  private func updateBackgroundColor() {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer?.backgroundColor = isHovering ? NSColor.gray.withAlphaComponent(0.1).cgColor : NSColor.clear.cgColor
    }
  }
}
