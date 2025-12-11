import AppKit

/// Lightweight surface-styled control for pinned tab bar actions (e.g. spaces button).
final class TabSurfaceButton: NSControl {
  var onTap: (() -> Void)?

  override var mouseDownCanMoveWindow: Bool { false }

  private let iconView = NonDraggableImageView()
  private var trackingArea: NSTrackingArea?
  private var isHovered = false
  private var isPressed = false

  private let symbolName: String
  private let pointSize: CGFloat
  private let weight: NSFont.Weight
  private let tintColor: NSColor

  init(
    symbolName: String,
    pointSize: CGFloat,
    weight: NSFont.Weight,
    tintColor: NSColor = .tertiaryLabelColor
  ) {
    self.symbolName = symbolName
    self.pointSize = pointSize
    self.weight = weight
    self.tintColor = tintColor
    super.init(frame: .zero)
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.backgroundColor = NSColor.clear.cgColor

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.contentTintColor = tintColor
    addSubview(iconView)

    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: pointSize),
      iconView.heightAnchor.constraint(equalToConstant: pointSize),
      widthAnchor.constraint(equalToConstant: 40),
      heightAnchor.constraint(equalToConstant: Theme.tabBarItemHeight - Theme.tabBarItemInset),
    ])

    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: .large)
    iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Route interactions to the control itself to avoid window-drag hits on subviews.
    bounds.contains(point) ? self : nil
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 40, height: Theme.tabBarItemHeight - Theme.tabBarItemInset)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovered = true
    updateAppearance()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovered = false
    isPressed = false
    updateAppearance()
  }

  override func mouseDown(with event: NSEvent) {
    isPressed = true
    updateAppearance()
    super.mouseDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    let containsPoint = bounds.contains(convert(event.locationInWindow, from: nil))
    if isPressed, containsPoint {
      onTap?()
      sendAction(action, to: target)
    }
    isPressed = false
    updateAppearance()
    super.mouseUp(with: event)
  }

  private func updateAppearance() {
    let base = isPressed ? 0.22 : (isHovered ? 0.15 : 0.0)
    layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(base).cgColor
  }
}
