import AppKit
import InlineKit
import InlineUI
import SwiftUI
import Translation

class EmbeddedMessageView: NSView {
  // MARK: - Constants

  private enum Constants {
    static let rectangleWidth: CGFloat = 3
    static let contentSpacing: CGFloat = 6
    static let verticalPadding: CGFloat = 4
    static let horizontalPadding: CGFloat = 6
    static let height: CGFloat = Theme.embeddedMessageHeight
    static let photoWidth: CGFloat = 32
    static let photoHeight: CGFloat = 32
  }

  // MARK: - Properties

  enum Kind {
    case replyInMessage
    case replyingInCompose
    case editingInCompose
    case forwardingInCompose
  }

  private var kind: Kind = .replyInMessage
  private var style: EmbeddedMessageStyle

  private var message: Message?
  private var relatedMessage: Message?
  private var senderNameForColor: String?
  private var simplePhotoView: SimplePhotoView?
  private var textLeadingConstraint: NSLayoutConstraint?
  private var photoConstraints: [NSLayoutConstraint] = []

  private var cornerRadius: CGFloat {
    switch kind {
      case .replyInMessage:
        8
      default:
        0
    }
  }

  private var senderFont: NSFont {
    .systemFont(ofSize: 12, weight: .semibold)
  }

  private var messageFont: NSFont {
    Theme.messageTextFont
  }

  private var textColor: NSColor {
    if style == .colored {
      .labelColor
    } else {
      .white
    }
  }

  private var senderColor: NSColor {
    guard let senderNameForColor else {
      return NSColor.controlAccentColor
    }
    let swiftUIColor = AvatarColorUtility.colorFor(name: senderNameForColor)
    return NSColor(swiftUIColor)
  }

  private var shouldUseSenderColor: Bool {
    style == .colored && kind == .replyInMessage
  }

  private var rectangleColor: NSColor {
    if style == .colored {
      shouldUseSenderColor ? senderColor : NSColor.controlAccentColor
    } else {
      NSColor.white
    }
  }

  private var nameLabelColor: NSColor {
    if style == .colored {
      shouldUseSenderColor ? senderColor : NSColor.controlAccentColor
    } else {
      NSColor.white
    }
  }

  private var backgroundColor: NSColor? {
    guard kind == .replyInMessage else { return nil }

    if style == .colored {
      return senderColor.withAlphaComponent(0.08)
    } else {
      return NSColor.white.withAlphaComponent(0.09)
    }
  }

  // MARK: - Views

  override var wantsUpdateLayer: Bool {
    true
  }

  private lazy var rectangleView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    view.layer?.masksToBounds = true
    view.layer?.backgroundColor = rectangleColor.cgColor
    return view
  }()

  private lazy var nameLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = senderFont
    label.lineBreakMode = .byTruncatingTail
    label.textColor = textColor
    label.heightAnchor.constraint(equalToConstant: Theme.messageNameLabelHeight).isActive = true
    return label
  }()

  private lazy var messageLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = messageFont
    label.lineBreakMode = .byTruncatingTail
    label.textColor = textColor
    label.maximumNumberOfLines = 1
    label.cell?.usesSingleLineMode = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    return label
  }()

  enum EmbeddedMessageStyle {
    case colored
    case white
  }

  // MARK: - Initialization

  init(style: EmbeddedMessageStyle) {
    self.style = style
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    wantsLayer = true
    layer?.cornerRadius = cornerRadius
    layer?.masksToBounds = true

    translatesAutoresizingMaskIntoConstraints = false

    addSubview(rectangleView)
    addSubview(nameLabel)
    addSubview(messageLabel)

    textLeadingConstraint = nameLabel.leadingAnchor.constraint(
      equalTo: rectangleView.trailingAnchor, constant: Constants.contentSpacing
    )

    NSLayoutConstraint.activate([
      // Height
      heightAnchor.constraint(equalToConstant: Constants.height),

      // Rectangle view
      rectangleView.leadingAnchor.constraint(equalTo: leadingAnchor),
      rectangleView.widthAnchor.constraint(equalToConstant: Constants.rectangleWidth),
      rectangleView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
      rectangleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),

      // Name label
      textLeadingConstraint!,
      nameLabel.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -Constants.horizontalPadding
      ),
      nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: Constants.verticalPadding),

      // Message label
      messageLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
      messageLabel.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -Constants.horizontalPadding
      ),
      messageLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor),
      messageLabel.bottomAnchor.constraint(
        equalTo: bottomAnchor, constant: -Constants.verticalPadding
      ),
    ])

    let clickGesture = NSClickGestureRecognizer(
      target: self,
      action: #selector(handleTap)
    )
    addGestureRecognizer(clickGesture)
  }

  func setRelatedMessage(_ message: Message) {
    relatedMessage = message
  }

  @objc func handleTap(_ gesture: NSClickGestureRecognizer) {
    guard let message else { return }
    guard message.status != .sending, message.status != .failed else { return }

    let messageId = message.messageId
    let chatState = ChatsManager.shared.get(for: message.peerId, chatId: message.chatId)

    chatState.scrollTo(msgId: messageId)
  }

  func update(with embeddedMessage: EmbeddedMessage, kind: Kind) {
    guard let from = embeddedMessage.from else {
      messageLabel.stringValue = "Unknown sender"
      return
    }

    let messageContent: String = if let displayText = embeddedMessage.displayTextForLastMessage, !displayText.isEmpty {
      displayText
    } else {
      getMessageContentText(from: embeddedMessage.message)
    }

    updateView(
      message: embeddedMessage.message,
      from: from,
      kind: kind,
      photoInfo: embeddedMessage.photoInfo,
      videoInfo: embeddedMessage.videoInfo,
      messageContent: messageContent
    )
  }

  func update(with fullMessage: FullMessage, kind: Kind) {
    guard let from = fullMessage.from else {
      messageLabel.stringValue = "Unknown sender"
      return
    }

    let messageContent: String = if let displayText = fullMessage.displayTextForLastMessage, !displayText.isEmpty {
      displayText
    } else {
      getMessageContentText(from: fullMessage.message)
    }

    updateView(
      message: fullMessage.message,
      from: from,
      kind: kind,
      photoInfo: fullMessage.photoInfo,
      videoInfo: fullMessage.videoInfo,
      messageContent: messageContent
    )
  }

  private func updateView(
    message: Message,
    from: User,
    kind: Kind,
    photoInfo: PhotoInfo?,
    videoInfo: VideoInfo?,
    messageContent: String
  ) {
    self.kind = kind
    self.message = message

    let senderName = from.fullName

    // Set sender name for color calculation
    senderNameForColor = AvatarColorUtility.formatNameForHashing(
      firstName: from.firstName,
      lastName: from.lastName,
      email: from.email
    )

    nameLabel.stringValue = switch kind {
      case .replyInMessage:
        "\(senderName)"

      case .replyingInCompose:
        "Reply to \(senderName)"

      case .editingInCompose:
        "Edit Message"

      case .forwardingInCompose:
        "Forward Message"
    }

    // Update visuals after setting senderNameForColor
    rectangleView.layer?.backgroundColor = rectangleColor.cgColor
    nameLabel.textColor = nameLabelColor
    layer?.backgroundColor = backgroundColor?.cgColor
    layer?.cornerRadius = cornerRadius

    // Handle photo if available
    let previewPhoto = photoInfo ?? videoInfo?.thumbnail
    let overlaySymbol = videoInfo != nil ? "play.circle.fill" : nil
    updatePhotoView(photoInfo: previewPhoto, overlaySymbol: overlaySymbol)

    if kind == .forwardingInCompose {
      messageLabel.stringValue = forwardDescription(for: senderName, messageText: messageContent)
    } else {
      messageLabel.stringValue = messageContent
    }
  }

  private func forwardDescription(for senderName: String, messageText: String) -> String {
    "\(senderName): \(messageText)"
  }

  private func getMessageContentText(from message: Message) -> String {
    if message.isSticker == true {
      "Sticker"
    } else if let _ = message.photoId {
      "Photo"
    } else if let _ = message.videoId {
      "🎥 Video"
    } else if let _ = message.documentId {
      "📄 Document"
    } else {
      "Message"
    }
  }

  private func updatePhotoView(photoInfo: PhotoInfo?, overlaySymbol: String?) {
    if let photoInfo {
      if let existingPhotoView = simplePhotoView {
        existingPhotoView.update(with: photoInfo, overlaySymbol: overlaySymbol)
      } else {
        let photoView = SimplePhotoView(
          photoInfo: photoInfo,
          width: Constants.photoWidth,
          height: Constants.photoHeight,
          relatedMessage: relatedMessage,
          overlaySymbol: overlaySymbol
        )
        simplePhotoView = photoView
        addSubview(photoView)

        photoConstraints = [
          photoView.leadingAnchor.constraint(
            equalTo: rectangleView.trailingAnchor, constant: Constants.contentSpacing
          ),
          photoView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        NSLayoutConstraint.activate(photoConstraints)

        // Update text leading constraint to be after photo
        textLeadingConstraint?.isActive = false
        textLeadingConstraint = nameLabel.leadingAnchor.constraint(
          equalTo: photoView.trailingAnchor, constant: Constants.contentSpacing
        )
        textLeadingConstraint?.isActive = true
      }
    } else {
      if let photoView = simplePhotoView {
        photoView.removeFromSuperview()
        simplePhotoView = nil

        NSLayoutConstraint.deactivate(photoConstraints)
        photoConstraints = []

        // Restore original text leading constraint
        textLeadingConstraint?.isActive = false
        textLeadingConstraint = nameLabel.leadingAnchor.constraint(
          equalTo: rectangleView.trailingAnchor, constant: Constants.contentSpacing
        )
        textLeadingConstraint?.isActive = true
      }
    }
  }
}
