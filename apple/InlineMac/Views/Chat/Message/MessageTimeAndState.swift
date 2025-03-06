import AppKit
import InlineKit
import InlineUI
import SwiftUI
import Logger

/// if outgoing message: [ [symbol] [time] ]
/// if incoming message: [          [time] ]

class MessageTimeAndState: NSView {
  private var fullMessage: FullMessage

  init(fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    super.init(frame: NSRect(x: 0, y: 0, width: Theme.messageAvatarSize, height: Theme.messageAvatarSize))
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
    label.textColor = .tertiaryLabelColor
    label.font = .systemFont(ofSize: 11)

    return label
  }()

  private var imageSize: CGFloat = 10
  private var currentState = MessageSendingStatus.sent

  private lazy var imageView = {
    let imageView = NSImageView()

    imageView.contentTintColor = .tertiaryLabelColor
    imageView.image = getSymbolImage()
    currentState = fullMessage.message.status ?? .sent
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
      timeLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
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

  // Reverse layout
//  private func setupView() {
//    addSubview(timeLabel)
//
//    NSLayoutConstraint.activate([
//      timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
//      timeLabel.topAnchor.constraint(equalTo: topAnchor),
//      timeLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
//    ])
//
//    if hasSymbol {
//      addSubview(imageView)
//
//      NSLayoutConstraint.activate([
//        imageView.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -4),
//        imageView.widthAnchor.constraint(equalToConstant: 12),
//        imageView.heightAnchor.constraint(equalToConstant: 12),
//        imageView.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
//
//        imageView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor)
//      ])
//    } else {
//      NSLayoutConstraint.activate([
//        timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor)
//      ])
//    }
//  }

  static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter
  }()

  private func setupContent() {
    Log.shared.debug("updating time and state")
    if isFailedMessage {
      timeLabel.stringValue = "Failed"
    } else {
      let time = Self.formatter.string(from: fullMessage.message.date)
      timeLabel.stringValue = time
    }

    if hasSymbol, currentState != fullMessage.message.status {
      currentState = fullMessage.message.status ?? .sent

      if #available(macOS 14.0, *) {
        imageView
          .setSymbolImage(
            getSymbolImage(),
            contentTransition: .replace.offUp,
            options: .speed(1.5)
          )
      } else {
        imageView.image = getSymbolImage()
      }
    }
    updateImageTintColor()
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
    imageView.contentTintColor = isFailedMessage ? .systemRed : .tertiaryLabelColor
  }

  // MARK: - Public

  public func updateMessage(_ fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    setupContent()
  }
}
