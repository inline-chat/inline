import AppKit

protocol ComposeEmojiButtonDelegate: AnyObject {
  func composeEmojiButton(_ button: ComposeEmojiButton, didReceiveText text: String)
  func composeEmojiButton(_ button: ComposeEmojiButton, didReceiveSticker image: NSImage)
}

final class ComposeEmojiButton: NSView {
  private let mode: ComposeControlMode
  private var size: CGFloat { mode.emojiButtonSize }
  private let button: NSButton
  private let textView: NSTextView
  private let scrollView: NSScrollView
  private var isHandlingChange = false
  private let stickerDetector = ComposeStickerDetector()
  private var trackingArea: NSTrackingArea?
  private var isHovering = false
  weak var delegate: ComposeEmojiButtonDelegate?

  private var canShowEmojiPanel: Bool {
    !isHidden && alphaValue > 0 && window != nil
  }

  override init(frame frameRect: NSRect) {
    mode = .legacy
    button = Self.makeButton(mode: mode)

    textView = NSTextView(frame: .zero)
    scrollView = NSScrollView(frame: .zero)
    super.init(frame: frameRect)
    setupView()
  }

  init(mode: ComposeControlMode) {
    self.mode = mode
    button = Self.makeButton(mode: mode)

    textView = NSTextView(frame: .zero)
    scrollView = NSScrollView(frame: .zero)
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

    textView.isEditable = true
    textView.isSelectable = true
    textView.isRichText = true
    textView.drawsBackground = false
    textView.textColor = NSColor.clear
    textView.insertionPointColor = NSColor.clear
    textView.importsGraphics = true
    textView.alignment = .center
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.delegate = self

    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    // AppKit's emoji panel inserts into the first responder text view. Keep a
    // tiny receiver around for insertion, but make the visible affordance a
    // real button.
    scrollView.alphaValue = 0
    scrollView.documentView = textView
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(scrollView)
    addSubview(button)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size),
      heightAnchor.constraint(equalToConstant: size),

      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.widthAnchor.constraint(equalToConstant: 1),
      scrollView.heightAnchor.constraint(equalToConstant: 1),
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
      guard self.canShowEmojiPanel else { return }
      self.showEmojiPanel()
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

  private func showEmojiPanel() {
    guard canShowEmojiPanel else { return }
    _ = window?.makeFirstResponder(textView)
    let showSelector = Selector(("showEmojiAndSymbols:"))
    if NSApplication.shared.sendAction(showSelector, to: nil, from: textView) == false {
      NSApplication.shared.orderFrontCharacterPalette(nil)
    }
  }

  func resignEmojiFocus() {
    guard window?.firstResponder === textView else { return }
    window?.makeFirstResponder(nil)
  }
}

extension ComposeEmojiButton: NSTextViewDelegate {
  func textDidChange(_ notification: Notification) {
    guard isHandlingChange == false else { return }
    let attributedString = textView.attributedString()
    var didHandle = false

    if #available(macOS 15.0, *) {
      let stickers = stickerDetector.detectStickers(in: attributedString)
      if stickers.isEmpty == false {
        for sticker in stickers {
          delegate?.composeEmojiButton(self, didReceiveSticker: sticker.image)
        }
        didHandle = true
      }
    }

    if !didHandle {
      let text = filteredPlainText(from: attributedString)
      if text.isEmpty == false {
        delegate?.composeEmojiButton(self, didReceiveText: text)
        didHandle = true
      }
    }

    isHandlingChange = true
    if didHandle {
      textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
    }
    isHandlingChange = false
  }

  private func filteredPlainText(from attributedString: NSAttributedString) -> String {
    let placeholder = "\u{FFFC}"
    let raw = attributedString.string
    let cleaned = raw
      .replacingOccurrences(of: placeholder, with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = cleaned.filter { character in
      character.unicodeScalars.contains { !$0.isASCII }
    }
    return String(filtered)
  }
}
