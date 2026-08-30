import AppKit

final class ComposeSilentModeButton: NSView {
  static let controlSize: CGFloat = Theme.composeButtonSize * 0.94

  private let mode: ComposeControlMode
  private let presentation: ComposeControlPresentation
  private var size: CGFloat { mode.silentButtonSize }
  private var usesCustomHoverFill: Bool {
    mode.usesCustomHoverFill || presentation == .accessoryBar
  }
  private let button: NSButton
  private var trackingArea: NSTrackingArea?
  private var isHovering = false

  var onClick: (() -> Void)?

  var isEnabled: Bool {
    get { button.isEnabled }
    set {
      button.isEnabled = newValue
      if !newValue {
        isHovering = false
      }
      updateBackgroundColor()
    }
  }

  override init(frame frameRect: NSRect) {
    mode = .legacy
    presentation = .standard
    button = Self.makeButton(mode: mode)

    super.init(frame: frameRect)
    setupView()
  }

  init(mode: ComposeControlMode, presentation: ComposeControlPresentation = .standard) {
    self.mode = mode
    self.presentation = presentation
    button = Self.makeButton(mode: mode)

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
    wantsLayer = true
    layer?.cornerRadius = size / 2
    layer?.masksToBounds = true

    button.target = self
    button.action = #selector(handleClick)
    addSubview(button)

    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    toolTip = "Send silently is enabled for this chat. Click to turn it off."
  }

  private static func makeButton(mode: ComposeControlMode) -> NSButton {
    let button = NSButton(frame: .zero)
    button.bezelStyle = .regularSquare
    button.isBordered = false
    button.translatesAutoresizingMaskIntoConstraints = false
    button.imageScaling = .scaleNone
    button.image = NSImage(systemSymbolName: "bell.slash", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: mode.silentIconPointSize, weight: .medium))
    button.contentTintColor = .tertiaryLabelColor
    button.setAccessibilityLabel("Disable send silently")
    return button
  }

  /// New-thread Compose exposes both states; existing chats keep their
  /// enabled-only indicator until they explicitly opt into this presentation.
  func updateSendSilently(_ enabled: Bool) {
    button.setButtonType(.toggle)
    button.state = enabled ? .on : .off
    button.image = NSImage(systemSymbolName: enabled ? "bell.slash" : "bell", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: mode.silentIconPointSize, weight: .medium))
    button.contentTintColor = .labelColor
    button.setAccessibilityRole(.checkBox)
    button.setAccessibilityLabel("Silent mode")
    button.setAccessibilityValue(enabled ? 1 : 0)
    toolTip = nil
  }

  override func layout() {
    super.layout()
    layer?.cornerRadius = bounds.height / 2
  }

  @objc private func handleClick() {
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
    guard usesCustomHoverFill, button.isEnabled else {
      layer?.backgroundColor = NSColor.clear.cgColor
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = presentation == .accessoryBar ? 0.2 : 0.12
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer?.backgroundColor = isHovering ? NSColor.gray.withAlphaComponent(0.1).cgColor : NSColor.clear.cgColor
    }
  }
}
