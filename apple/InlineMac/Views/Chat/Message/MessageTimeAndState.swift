import AppKit
import InlineKit
import InlineUI
import Logger
import SwiftUI

/// if outgoing message: [ [time] [symbol] ]
/// if incoming message: [          [time] ]

class MessageTimeAndState: NSView {
  private var fullMessage: FullMessage

  private var textColor: NSColor {
    fullMessage.message.out == true ? .white
      .withAlphaComponent(0.5) : .tertiaryLabelColor
  }

  init(fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    super.init(frame: .zero)
    wantsLayer = true
    setupView()
    setupContent()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private lazy var timeLabel = {
    let label = NSTextField()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.isEditable = false
    label.isSelectable = false
    label.isBezeled = false
    label.drawsBackground = false
    label.textColor = textColor
    label.font = NSFont.systemFont(ofSize: 10, weight: .regular).withTraits(.italic)

    return label
  }()

  private var imageSize: CGFloat = 10
  private var currentState: MessageSendingStatus = .sent

  private lazy var imageView = {
    let imageView = NSImageView()
    imageView.wantsLayer = true
    imageView.layer?.shouldRasterize = true
    imageView.layer?.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 1.0
    imageView.contentTintColor = isFailedMessage ? .systemRed : textColor
    imageView.image = getSymbolImage()
    imageView.imageScaling = .scaleNone
    imageView.translatesAutoresizingMaskIntoConstraints = false

    return imageView
  }()

  private var hasSymbol: Bool {
    fullMessage.message.out == true
  }

  private var isFailedMessage: Bool {
    fullMessage.message.status == .failed
  }

  private func setupView() {
    addSubview(timeLabel)

    NSLayoutConstraint.activate([
      // timeLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
      timeLabel.topAnchor.constraint(equalTo: topAnchor),
      timeLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    if hasSymbol {
      addSubview(imageView)

      NSLayoutConstraint.activate([
        imageView.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 2),
        imageView.widthAnchor.constraint(equalToConstant: 12),
        imageView.heightAnchor.constraint(equalToConstant: 12),
        imageView.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),

        imageView.trailingAnchor.constraint(greaterThanOrEqualTo: trailingAnchor),
      ])
    } else {
      NSLayoutConstraint.activate([
        timeLabel.trailingAnchor.constraint(greaterThanOrEqualTo: trailingAnchor),
      ])
    }
  }

  static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter
  }()

  private func setupContent() {
    updateTimeLabel()

    if hasSymbol {
      updateStatusImage(animated: false)
    }
  }

  private func getSymbolImage() -> NSImage {
    let status = fullMessage.message.status ?? .sent
    let image = switch status {
      case .sent:
        NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Sent")!.withSymbolConfiguration(
          .init(pointSize: 9, weight: .medium).applying(.preferringMonochrome())
        )!
      case .sending:
        NSImage(systemSymbolName: "clock", accessibilityDescription: "Sending")!.withSymbolConfiguration(
          .init(pointSize: 9, weight: .medium).applying(.preferringMonochrome())
        )!
      case .failed:
        NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Failed")!
          .withSymbolConfiguration(
            .init(pointSize: 9, weight: .medium).applying(.preferringMonochrome())
          )!
    }

    return image
  }

  private func updateImageTintColor() {
    imageView.contentTintColor = isFailedMessage ? .systemRed : textColor
  }

  // MARK: - Public

  public func updateMessage(_ fullMessage: FullMessage) {
    // Check if we actually need to update
    let oldStatus = self.fullMessage.message.status
    let oldDate = self.fullMessage.message.date
    let oldOut = self.fullMessage.message.out

    self.fullMessage = fullMessage

    // Only update what changed
    let newStatus = fullMessage.message.status
    let newDate = fullMessage.message.date
    let newOut = fullMessage.message.out

    if oldDate != newDate || oldOut != newOut || oldStatus != newStatus {
      updateTimeLabel()
    }

    if oldStatus != newStatus {
      updateStatusImage()
    }

    if oldOut != newOut {
      updateTextColor()
    }
  }

  private func updateTimeLabel() {
    if isFailedMessage {
      timeLabel.stringValue = "Failed"
    } else {
      timeLabel.stringValue = Self.formatter.string(from: fullMessage.message.date)
    }
  }

  private func updateStatusImage(animated: Bool = true) {
    if currentState != fullMessage.message.status {
      currentState = fullMessage.message.status ?? .sent

      if animated, #available(macOS 14.0, *) {
        imageView.setSymbolImage(
          getSymbolImage(),
          contentTransition: .replace.offUp,
          options: .speed(1.5)
        )
      } else {
        imageView.image = getSymbolImage()
      }
      updateImageTintColor()
    }
  }

  private func updateTextColor() {
    let newColor: NSColor = fullMessage.message.out == true ?
      .white.withAlphaComponent(0.5) : .tertiaryLabelColor

    timeLabel.textColor = newColor
    if !isFailedMessage {
      imageView.contentTintColor = newColor
    }
  }
}
