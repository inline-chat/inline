import AppKit

final class ComposeVoiceButton: NSView {
  private let mode: ComposeControlMode
  private let presentation: ComposeControlPresentation
  private let fixedInputMode: ComposeVoiceInputMode?
  private var size: CGFloat { mode.voiceButtonSize }
  private let contentView: NSView
  private let glassButton: NSButton?
  private var trackingArea: NSTrackingArea?
  private var isHovering = false

  var onClick: (() -> Void)?
  var onModeChanged: (() -> Void)?
  var isEnabled = true {
    didSet { glassButton?.isEnabled = isEnabled }
  }

  override init(frame frameRect: NSRect) {
    mode = .legacy
    presentation = .standard
    fixedInputMode = nil
    let content = Self.makeContent(mode: mode)
    contentView = content.view
    glassButton = content.button

    super.init(frame: frameRect)
    setupView()
  }

  init(
    mode: ComposeControlMode,
    presentation: ComposeControlPresentation = .standard,
    fixedInputMode: ComposeVoiceInputMode? = nil
  ) {
    self.mode = mode
    self.presentation = presentation
    self.fixedInputMode = fixedInputMode
    let content = Self.makeContent(mode: mode, presentation: presentation)
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
    if presentation == .accessoryBar {
      wantsLayer = true
      layer?.cornerRadius = mode.silentButtonSize / 2
    }

    addSubview(contentView)
    NotificationCenter.default.addObserver(
      self, selector: #selector(inputPreferencesDidChange), name: UserDefaults.didChangeNotification, object: nil
    )

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
    refreshInputMode()
  }

  private static func makeContent(
    mode: ComposeControlMode,
    presentation: ComposeControlPresentation = .standard
  ) -> (view: NSView, button: NSButton?) {
    let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Record voice message")?
      .withSymbolConfiguration(.init(pointSize: mode.voiceButtonIconPointSize, weight: .medium))

    if presentation == .accessoryBar {
      let button = NSButton(frame: .zero)
      button.translatesAutoresizingMaskIntoConstraints = false
      button.imagePosition = .imageOnly
      button.imageScaling = .scaleNone
      button.bezelStyle = .regularSquare
      button.isBordered = false
      button.contentTintColor = .secondaryLabelColor
      return (button, button)
    }

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
    guard isEnabled else { return }
    onClick?()
  }

  override func mouseDown(with event: NSEvent) {
    guard glassButton == nil else { return }
    super.mouseDown(with: event)
    guard isEnabled else { return }
    onClick?()
  }

  @objc nonisolated private func inputPreferencesDidChange() {
    Task { @MainActor [weak self] in self?.refreshInputMode() }
  }

  private func refreshInputMode() {
    let selected = fixedInputMode ?? ComposeVoiceInputMode.selected
    let iconSize = presentation == .accessoryBar ? mode.silentIconPointSize : mode.voiceButtonIconPointSize
    let image = NSImage(systemSymbolName: selected.symbol, accessibilityDescription: selected.actionTitle)?
      .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium))
    glassButton?.image = image
    (contentView as? NSImageView)?.image = image
    toolTip = selected.actionTitle
    glassButton?.toolTip = selected.actionTitle
    setAccessibilityLabel(selected.actionTitle)
    glassButton?.setAccessibilityLabel(selected.actionTitle)
    let menu = fixedInputMode == nil ? makeInputMenu() : nil
    self.menu = menu
    glassButton?.menu = menu
    onModeChanged?()
  }

  private func makeInputMenu() -> NSMenu {
    let menu = NSMenu()
    for mode in [ComposeVoiceInputMode.voiceMessage, .transcribe] {
      let item = NSMenuItem(title: mode.title, action: #selector(selectInputMode(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = mode.rawValue
      item.state = ComposeVoiceInputMode.selected == mode ? .on : .off
      item.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
      menu.addItem(item)
    }
    return menu
  }

  @objc private func selectInputMode(_ sender: NSMenuItem) {
    guard let value = sender.representedObject as? String, let mode = ComposeVoiceInputMode(rawValue: value) else { return }
    ComposeVoiceInputMode.selected = mode
    refreshInputMode()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let trackingArea {
      removeTrackingArea(trackingArea)
      self.trackingArea = nil
    }

    guard mode.usesCustomHoverFill || presentation == .accessoryBar else { return }

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
    guard isEnabled, mode.usesCustomHoverFill || presentation == .accessoryBar else {
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
