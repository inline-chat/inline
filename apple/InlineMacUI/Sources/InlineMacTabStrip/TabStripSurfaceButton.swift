import AppKit

final class TabStripSurfaceButton: NSControl {
  var onTap: (() -> Void)?

  override var mouseDownCanMoveWindow: Bool { false }

  private let iconView = TabStripNonDraggableImageView()
  private var trackingArea: NSTrackingArea?
  private var isHovered = false
  private var isPressed = false

  private let symbolName: String
  private let pointSize: CGFloat
  private let weight: NSFont.Weight
  private let tintColor: NSColor
  private let buttonWidth: CGFloat
  private let buttonHeight: CGFloat
  private let cornerRadius: CGFloat
  private let iconCenterYOffset: CGFloat

  init(
    symbolName: String,
    pointSize: CGFloat,
    weight: NSFont.Weight,
    tintColor: NSColor = .tertiaryLabelColor,
    width: CGFloat = 36,
    height: CGFloat = CollectionTabStripViewController.Layout.surfaceButtonHeight,
    cornerRadius: CGFloat = 10,
    iconCenterYOffset: CGFloat = CollectionTabStripViewController.Layout.surfaceButtonIconCenterYOffset
  ) {
    self.symbolName = symbolName
    self.pointSize = pointSize
    self.weight = weight
    self.tintColor = tintColor
    buttonWidth = width
    buttonHeight = height
    self.cornerRadius = cornerRadius
    self.iconCenterYOffset = iconCenterYOffset
    super.init(frame: .zero)
    setup()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setup() {
    wantsLayer = true
    layer?.cornerRadius = cornerRadius
    layer?.backgroundColor = NSColor.clear.cgColor

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.contentTintColor = tintColor
    addSubview(iconView)

    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: iconCenterYOffset),
      iconView.widthAnchor.constraint(equalToConstant: pointSize),
      iconView.heightAnchor.constraint(equalToConstant: pointSize),
      widthAnchor.constraint(equalToConstant: buttonWidth),
      heightAnchor.constraint(equalToConstant: buttonHeight),
    ])

    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight, scale: .large)
    iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
      .withSymbolConfiguration(config)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(point) ? self : nil
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: buttonWidth, height: buttonHeight)
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
    let alpha = isPressed ? 0.22 : (isHovered ? 0.15 : 0.0)
    layer?.backgroundColor = NSColor.systemGray.withAlphaComponent(alpha).cgColor
  }
}
