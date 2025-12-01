import AppKit

final class TabCloseOverlayView: NSView {
  var onClose: (() -> Void)?

  private let button = NonDraggableButton()
  private var trackingArea: NSTrackingArea?

  private var baseColor: NSColor = .white
  private var isDarkMode = false
  private var isHovered = false

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerRadius = 6

    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.setButtonType(.momentaryChange)
    button.imageScaling = .scaleProportionallyDown
    let symbolConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
    button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?
      .withSymbolConfiguration(symbolConfig)
    button.contentTintColor = .labelColor
    button.target = self
    button.action = #selector(handleTap)
    button.wantsLayer = true
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
    button.setContentHuggingPriority(.required, for: .horizontal)
    addSubview(button)

    NSLayoutConstraint.activate([
      button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.widthAnchor.constraint(equalToConstant: 18),
      button.heightAnchor.constraint(equalToConstant: 18),
    ])

    updateButtonBackground()
  }

  override func updateTrackingAreas() {
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
    let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovered = true
    updateButtonBackground()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovered = false
    updateButtonBackground()
  }

  func setBaseColor(_ color: NSColor, isDarkMode: Bool) {
    baseColor = color
    self.isDarkMode = isDarkMode
    updateButtonBackground()
  }

  func setVisible(_ visible: Bool) {
    alphaValue = visible ? 1 : 0
    isHidden = false
    button.isEnabled = visible
  }

  private func updateButtonBackground() {
    let hoverColor = baseColor.withAlphaComponent(isDarkMode ? 0.35 : 0.2)
    button.layer?.cornerRadius = 4
    button.layer?.backgroundColor = isHovered ? hoverColor.cgColor : NSColor.clear.cgColor
  }

  @objc private func handleTap() {
    onClose?()
  }
}
