import AppKit

protocol ComposeEmojiButtonDelegate: AnyObject {
  func composeEmojiButton(_ button: ComposeEmojiButton, didReceiveText text: String)
  func composeEmojiButton(_ button: ComposeEmojiButton, didReceiveSticker image: NSImage)
}

final class ComposeEmojiButton: NSView {
  private let size: CGFloat = Theme.composeButtonSize
  private let iconView: NSImageView
  private let textView: EmojiReceiverTextView
  private let scrollView: NSScrollView
  private var isHandlingChange = false
  private let stickerDetector = ComposeStickerDetector()
  private var trackingArea: NSTrackingArea?
  private var isHovering = false
  weak var delegate: ComposeEmojiButtonDelegate?

  override init(frame frameRect: NSRect) {
    let image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: size * 0.6, weight: .semibold))
    iconView = NSImageView(image: image ?? NSImage())
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentTintColor = .tertiaryLabelColor

    textView = EmojiReceiverTextView(frame: .zero)
    scrollView = NSScrollView(frame: .zero)
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
    wantsLayer = true
    layer?.cornerRadius = size / 2
    layer?.backgroundColor = NSColor.clear.cgColor

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
    textView.onFocus = { [weak self] in
      self?.focusWindowIfNeeded()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        self?.showEmojiPanel()
      }
    }

    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.documentView = textView
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    addSubview(iconView)
    addSubview(scrollView)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size),
      heightAnchor.constraint(equalToConstant: size),

      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),

      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  override func mouseDown(with event: NSEvent) {
    if let window {
      if !NSApplication.shared.isActive {
        NSApplication.shared.activate(ignoringOtherApps: true)
      }
      if !window.isKeyWindow {
        window.makeKeyAndOrderFront(nil)
      }
    }
    super.mouseDown(with: event)
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.textView.window?.firstResponder === self.textView {
        self.showEmojiPanel()
      } else {
        _ = self.window?.makeFirstResponder(self.textView)
      }
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
    _ = window?.makeFirstResponder(textView)
    let showSelector = Selector(("showEmojiAndSymbols:"))
    if NSApplication.shared.sendAction(showSelector, to: nil, from: textView) == false {
      NSApplication.shared.orderFrontCharacterPalette(nil)
    }
  }
}

private final class EmojiReceiverTextView: NSTextView {
  var onFocus: (() -> Void)?

  @discardableResult
  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
      onFocus?()
    }
    return result
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
