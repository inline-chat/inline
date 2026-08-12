import AppKit

final class ComposeVoiceButton: NSView {
  private let mode: ComposeControlMode
  private var size: CGFloat { mode.voiceButtonSize }
  private let contentView: NSView
  private let glassButton: NSButton?
  private var trackingArea: NSTrackingArea?
  private var isHovering = false

  var onClick: (() -> Void)?
  var isEnabled: Bool {
    get { glassButton?.isEnabled ?? true }
    set { glassButton?.isEnabled = newValue }
  }

  override init(frame frameRect: NSRect) {
    mode = .legacy
    let content = Self.makeContent(mode: mode)
    contentView = content.view
    glassButton = content.button

    super.init(frame: frameRect)
    setupView()
  }

  init(mode: ComposeControlMode) {
    self.mode = mode
    let content = Self.makeContent(mode: mode)
    contentView = content.view
    glassButton = content.button

    super.init(frame: .zero)
    setupView()
  }

  convenience init() {
    self.init(mode: .legacy)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    translatesAutoresizingMaskIntoConstraints = false

    addSubview(contentView)

    if let glassButton {
      // GlassComposeAppKit owns glass-mode geometry so its existing width
      // constraint can collapse this control without fighting a fixed self-size.
      NSLayoutConstraint.activate([
        contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
        contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
        contentView.topAnchor.constraint(equalTo: topAnchor),
        contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])

      glassButton.target = self
      glassButton.action = #selector(handleClick)
    } else {
      wantsLayer = true
      layer?.cornerRadius = size / 2
      layer?.masksToBounds = true
      toolTip = "Record voice message"

      NSLayoutConstraint.activate([
        widthAnchor.constraint(equalToConstant: size),
        heightAnchor.constraint(equalToConstant: size),
        contentView.centerXAnchor.constraint(equalTo: centerXAnchor),
        contentView.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }
  }

  private static func makeContent(mode: ComposeControlMode) -> (view: NSView, button: NSButton?) {
    let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Record voice message")?
      .withSymbolConfiguration(.init(pointSize: mode.voiceButtonIconPointSize, weight: .medium))

    if case .glass = mode {
      if #available(macOS 26.0, *) {
        let button = NSButton(frame: .zero)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.image = image
        button.toolTip = "Record voice message"
        button.setAccessibilityLabel("Record voice message")
        button.bezelStyle = .glass
        button.borderShape = .circle
        button.isBordered = true
        return (button, button)
      }
    }

    let iconView = NSImageView(image: image ?? NSImage())
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentTintColor = .tertiaryLabelColor
    return (iconView, nil)
  }

  @objc private func handleClick() {
    onClick?()
  }

  override func mouseDown(with event: NSEvent) {
    guard glassButton == nil else { return }
    super.mouseDown(with: event)
    onClick?()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let trackingArea {
      removeTrackingArea(trackingArea)
      self.trackingArea = nil
    }

    guard mode.usesCustomHoverFill else { return }

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
    guard mode.usesCustomHoverFill else {
      layer?.backgroundColor = NSColor.clear.cgColor
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer?.backgroundColor = isHovering ? NSColor.gray.withAlphaComponent(0.1).cgColor : NSColor.clear.cgColor
    }
  }
}
