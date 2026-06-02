import AppKit
import InlineKit

final class ComposeVoiceButton: NSView {
  private let size: CGFloat = Theme.composeButtonSize
  private let iconView: NSImageView
  private var trackingArea: NSTrackingArea?
  private var isHovering = false

  var onClick: (() -> Void)?

  override init(frame frameRect: NSRect) {
    let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Record voice message")?
      .withSymbolConfiguration(.init(pointSize: size * 0.56, weight: .semibold))
    iconView = NSImageView(image: image ?? NSImage())
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentTintColor = .tertiaryLabelColor

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
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    isHidden = !ExperimentalFeatureFlags.voiceMessagesEnabled
    layer?.cornerRadius = size / 2
    layer?.masksToBounds = true
    toolTip = "Record voice message"

    addSubview(iconView)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size),
      heightAnchor.constraint(equalToConstant: size),
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  override func layout() {
    super.layout()
    layer?.cornerRadius = bounds.height / 2
  }

  override func mouseDown(with event: NSEvent) {
    guard ExperimentalFeatureFlags.voiceMessagesEnabled else { return }
    super.mouseDown(with: event)
    onClick?()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    if let trackingArea {
      removeTrackingArea(trackingArea)
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
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer?.backgroundColor = isHovering ? NSColor.gray.withAlphaComponent(0.1).cgColor : NSColor.clear.cgColor
    }
  }
}
