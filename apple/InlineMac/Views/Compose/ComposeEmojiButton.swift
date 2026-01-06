import AppKit

final class ComposeEmojiButton: NSView {
  private let size: CGFloat = Theme.composeButtonSize
  private let button: NSButton
  private var trackingArea: NSTrackingArea?
  private var isHovering = false
  private let onClick: () -> Void

  init(onClick: @escaping () -> Void) {
    self.onClick = onClick

    button = NSButton(frame: .zero)
    button.bezelStyle = .regularSquare
    button.isBordered = false
    button.translatesAutoresizingMaskIntoConstraints = false

    let image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: size * 0.6, weight: .semibold))
    button.image = image
    button.contentTintColor = .tertiaryLabelColor

    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = size / 2

    addSubview(button)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size),
      heightAnchor.constraint(equalToConstant: size),

      button.centerXAnchor.constraint(equalTo: centerXAnchor),
      button.centerYAnchor.constraint(equalTo: centerYAnchor),
      button.widthAnchor.constraint(equalToConstant: size),
      button.heightAnchor.constraint(equalToConstant: size),
    ])

    button.target = self
    button.action = #selector(handleClick)
  }

  @objc private func handleClick() {
    onClick()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let existingTrackingArea = trackingArea {
      removeTrackingArea(existingTrackingArea)
    }

    let options: NSTrackingArea.Options = [
      .mouseEnteredAndExited,
      .activeAlways,
    ]

    trackingArea = NSTrackingArea(
      rect: bounds,
      options: options,
      owner: self,
      userInfo: nil
    )

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
      context.duration = 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

      if isHovering {
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.1).cgColor
      } else {
        layer?.backgroundColor = .clear
      }
    }
  }
}
