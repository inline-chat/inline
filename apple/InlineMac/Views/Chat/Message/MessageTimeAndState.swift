import AppKit
import InlineKit
import InlineUI
import Logger
import SwiftUI

class MessageTimeAndState: NSView {
  private var fullMessage: FullMessage
  private var currentState: MessageSendingStatus = .sent

  private var textColor: NSColor {
    fullMessage.message.out == true ? .white.withAlphaComponent(0.6) : .tertiaryLabelColor
  }

  private var hasSymbol: Bool {
    fullMessage.message.out == true
  }

  private var isFailedMessage: Bool {
    fullMessage.message.status == .failed
  }

  // MARK: - Layer Setup

  private lazy var timeLayer: CATextLayer = {
    let layer = CATextLayer()
    layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 1.0
    layer.font = NSFont.systemFont(ofSize: 10, weight: .regular)
    layer.fontSize = 10
    layer.alignmentMode = .left
    layer.truncationMode = .end
    layer.isWrapped = false
    return layer
  }()

  private lazy var statusLayer: CALayer = {
    let layer = CALayer()
    layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 1.0
    layer.contentsGravity = .center
    layer.masksToBounds = true
    return layer
  }()

  // MARK: - Initialization

  init(fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    super.init(frame: .zero)
    configureLayerSetup()
    updateContent()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configureLayerSetup() {
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.addSublayer(timeLayer)
    layer?.addSublayer(statusLayer)
    statusLayer.isHidden = !hasSymbol
  }

  // MARK: - Layout

  override func layout() {
    super.layout()

    let timeWidth = Self.timeWidth
    timeLayer.frame = CGRect(
      x: 4,
      y: (bounds.height - Self.timeHeight) / 2,
      width: timeWidth,
      height: Self.timeHeight // timeLayer.preferredFrameSize().height
    )

    if hasSymbol {
      statusLayer.frame = CGRect(
        x: timeWidth + 4,
        y: (bounds.height - 12) / 2,
        width: 12,
        height: 12
      )
    }
  }

  // MARK: - Content Updates

  public func updateMessage(_ fullMessage: FullMessage) {
    let oldStatus = self.fullMessage.message.status
    let oldDate = self.fullMessage.message.date
    let oldOut = self.fullMessage.message.out

    self.fullMessage = fullMessage

    if fullMessage.message.date != oldDate || fullMessage.message.out != oldOut {
      updateTimeContent()
    }

    if fullMessage.message.status != oldStatus {
      updateStatusContent()
    }

    if fullMessage.message.out != oldOut {
      updateColorStyles()
    }

    needsLayout = true
  }

  private func updateContent() {
    updateTimeContent()
    updateStatusContent()
    updateColorStyles()
  }

  private func updateTimeContent() {
    let string = isFailedMessage ? "Failed" : Self.formatter.string(from: fullMessage.message.date)
    timeLayer.string = NSAttributedString(
      string: string,
      attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .regular).withTraits(.italic),
        .foregroundColor: textColor,
      ]
    )
  }

  private func updateStatusContent() {
    guard hasSymbol else { return }
    statusLayer.contents = createStatusImage()
  }

  private func updateColorStyles() {
    timeLayer.foregroundColor = textColor.cgColor
    statusLayer.contents = createStatusImage()
  }

  // MARK: - Image Generation

  private func createStatusImage() -> CGImage? {
    let status = fullMessage.message.status ?? .sent
    let color = isFailedMessage ? NSColor.systemRed : textColor

    let imageName = switch status {
      case .sent: "checkmark"
      case .sending: "clock"
      case .failed: "exclamationmark.triangle"
    }

    let config = NSImage.SymbolConfiguration(
      pointSize: 11,
      weight: .semibold,
      scale: .small
    ).applying(.init(paletteColors: [color]))

    return NSImage(
      systemSymbolName: imageName,
      accessibilityDescription: nil
    )?
      .withSymbolConfiguration(config)?
      .cgImage(forProposedRect: nil, context: nil, hints: nil)
  }

  // External Sizing

  static var formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("jmm")
    formatter.locale = Locale.autoupdatingCurrent
    return formatter
  }()

  static var symbolWidth: CGFloat {
    14
  }

  static var font: NSFont {
    NSFont.systemFont(ofSize: 10, weight: .regular).withTraits(.italic)
  }

  static var timeWidth: CGFloat = 0.0
  static var timeHeight: CGFloat = 0.0

  // Must be called once
  static func precalculateTimeWidth() {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("jmm")
    formatter.locale = Locale.autoupdatingCurrent

    MessageTimeAndState.formatter = formatter

    let timeFormatIs12Hour = (formatter.dateFormat ?? "").contains("a")
    let maxTimeString =
      if timeFormatIs12Hour {
        "12:59 PM"
      } else {
        "23:59"
      }

    let attributes: [NSAttributedString.Key: Any] = [
      .font: MessageTimeAndState.font,
    ]
    let size = NSAttributedString(
      string: maxTimeString,
      attributes: attributes
    ).size()
    let timeWidth = size.width.rounded(.up)
    let timeHeight = size.height.rounded(.up)

    MessageTimeAndState.timeWidth = timeWidth
    MessageTimeAndState.timeHeight = timeHeight
  }
}
