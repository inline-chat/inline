import AppKit

protocol ComposeEmojiButtonDelegate: AnyObject {
  func composeEmojiButton(_ button: ComposeEmojiButton, didReceiveText text: String)
  func composeEmojiButton(_ button: ComposeEmojiButton, didReceiveSticker image: NSImage)
}

final class ComposeEmojiButton: NSView {
  private let mode: ComposeControlMode
  private var size: CGFloat { mode.emojiButtonSize }
  private let button: NSButton
  private var trackingArea: NSTrackingArea?
  private var emojiPopover: NSPopover?
  private var isHovering = false
  weak var delegate: ComposeEmojiButtonDelegate?

  private var canShowEmojiPopover: Bool {
    !isHidden && alphaValue > 0 && window != nil
  }

  override var isHidden: Bool {
    didSet {
      if isHidden {
        setHovering(false)
      } else {
        refreshHoverState()
      }
    }
  }

  override init(frame frameRect: NSRect) {
    mode = .legacy
    button = Self.makeButton(mode: mode)
    super.init(frame: frameRect)
    setupView()
  }

  init(mode: ComposeControlMode) {
    self.mode = mode
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
    layer?.backgroundColor = NSColor.clear.cgColor

    button.target = self
    button.action = #selector(handleClick)
    button.toolTip = "Emoji"
    button.setAccessibilityLabel("Emoji")

    addSubview(button)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size),
      heightAnchor.constraint(equalToConstant: size),

      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  private static func makeButton(mode: ComposeControlMode) -> NSButton {
    let button = NSButton(frame: .zero)
    button.bezelStyle = .regularSquare
    button.isBordered = false
    button.translatesAutoresizingMaskIntoConstraints = false
    button.imageScaling = .scaleNone
    button.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Emoji")?
      .withSymbolConfiguration(.init(pointSize: mode.emojiIconPointSize, weight: .medium))
    button.contentTintColor = .tertiaryLabelColor
    return button
  }

  @objc private func handleClick() {
    focusWindowIfNeeded()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.canShowEmojiPopover else { return }
      self.showEmojiPopover()
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let existingTrackingArea = trackingArea {
      removeTrackingArea(existingTrackingArea)
    }

    let options: NSTrackingArea.Options = [
      .mouseEnteredAndExited,
      .activeAlways,
      .inVisibleRect,
    ]

    trackingArea = NSTrackingArea(
      rect: .zero,
      options: options,
      owner: self,
      userInfo: nil
    )

    if let trackingArea {
      addTrackingArea(trackingArea)
    }
  }

  override func mouseEntered(with event: NSEvent) {
    setHovering(true)
  }

  override func mouseExited(with event: NSEvent) {
    setHovering(false)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    if window == nil {
      setHovering(false)
    } else {
      refreshHoverState()
    }
  }

  private func refreshHoverState() {
    guard canShowEmojiPopover, let window else {
      setHovering(false)
      return
    }

    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    setHovering(bounds.contains(point))
  }

  private func setHovering(_ hovering: Bool) {
    guard isHovering != hovering else { return }

    isHovering = hovering
    updateBackgroundColor()
  }

  private func updateBackgroundColor() {
    guard mode.usesCustomHoverFill else {
      layer?.backgroundColor = NSColor.clear.cgColor
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

      if isHovering {
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.1).cgColor
      } else {
        layer?.backgroundColor = NSColor.clear.cgColor
      }
    }
  }

  private func focusWindowIfNeeded() {
    guard let window else { return }
    if !NSApplication.shared.isActive {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    if !window.isKeyWindow {
      window.makeKeyAndOrderFront(nil)
    }
  }

  private func showEmojiPopover() {
    guard canShowEmojiPopover else { return }
    if emojiPopover?.isShown == true {
      emojiPopover?.performClose(nil)
      return
    }

    let popover = makeEmojiPopover()
    emojiPopover = popover
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    setHovering(false)
  }

  func resignEmojiFocus() {
    emojiPopover?.performClose(nil)
  }

  private func makeEmojiPopover() -> NSPopover {
    let popover = EmojiPickerPopover2.makePopover { [weak self] emoji in
      guard let self else { return }
      delegate?.composeEmojiButton(self, didReceiveText: emoji)
    }
    popover.delegate = self
    return popover
  }
}

extension ComposeEmojiButton: NSPopoverDelegate {
  func popoverDidClose(_ notification: Notification) {
    guard notification.object as? NSPopover === emojiPopover else { return }
    emojiPopover = nil
    refreshHoverState()
  }
}
