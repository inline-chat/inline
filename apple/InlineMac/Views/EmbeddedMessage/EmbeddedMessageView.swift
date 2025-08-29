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
  }

  // MARK: - Properties

  enum Kind {
    case replyInMessage
    case replyingInCompose
    case editingInCompose
  }

  private var kind: Kind = .replyInMessage
  private var style: EmbeddedMessageStyle

  private var message: Message?
  private var senderNameForColor: String?

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

    NSLayoutConstraint.activate([
      // Height
      heightAnchor.constraint(equalToConstant: Constants.height),

      // Rectangle view
      rectangleView.leadingAnchor.constraint(equalTo: leadingAnchor),
      rectangleView.widthAnchor.constraint(equalToConstant: Constants.rectangleWidth),
      rectangleView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
      rectangleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),

      // Name label
      nameLabel.leadingAnchor.constraint(
        equalTo: rectangleView.trailingAnchor, constant: Constants.contentSpacing
      ),
      nameLabel.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -Constants.horizontalPadding
      ),
      nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: Constants.verticalPadding),

      // Message label
      messageLabel.leadingAnchor.constraint(
        equalTo: rectangleView.trailingAnchor, constant: Constants.contentSpacing
      ),
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

  @objc func handleTap(_ gesture: NSClickGestureRecognizer) {
    guard let message else { return }
    guard message.status != .sending, message.status != .failed else { return }

    let messageId = message.messageId
    let chatState = ChatsManager.shared.get(for: message.peerId, chatId: message.chatId)

    chatState.scrollTo(msgId: messageId)
  }

  func update(with embeddedMessage: EmbeddedMessage, kind: Kind) {
    self.kind = kind
    self.message = embeddedMessage.message

    guard let from = embeddedMessage.from else {
      messageLabel.stringValue = "Unknown sender"
      return
    }

    let senderName = from.fullName

    // Set sender name for color calculation
    senderNameForColor = AvatarColorUtility.formatNameForHashing(
      firstName: from.firstName,
      lastName: from.lastName,
      email: from.email
    )

    nameLabel.stringValue = switch self.kind {
      case .replyInMessage:
        "\(senderName)"

      case .replyingInCompose:
        "Reply to \(senderName)"

      case .editingInCompose:
        "Edit Message"
    }

    // Update colors after setting senderNameForColor
    rectangleView.layer?.backgroundColor = rectangleColor.cgColor
    nameLabel.textColor = nameLabelColor
    layer?.backgroundColor = backgroundColor?.cgColor

    let message = embeddedMessage.message

    // Use display text which handles translations
    if let displayText = embeddedMessage.displayText, !displayText.isEmpty {
      messageLabel.stringValue = displayText
    } else if message.isSticker == true {
      messageLabel.stringValue = "🖼️ Sticker"
    } else if let _ = message.photoId {
      messageLabel.stringValue = "🖼️ Photo"
    } else if let _ = message.videoId {
      messageLabel.stringValue = "🎥 Video"
    } else if let _ = message.documentId {
      messageLabel.stringValue = "📄 Document"
    } else {
      messageLabel.stringValue = "Message"
    }
  }

  func update(with fullMessage: FullMessage, kind: Kind) {
    self.kind = kind
    message = fullMessage.message

    guard let from = fullMessage.from else {
      messageLabel.stringValue = "Unknown sender"
      return
    }

    let senderName = from.fullName

    // Set sender name for color calculation
    senderNameForColor = AvatarColorUtility.formatNameForHashing(
      firstName: from.firstName,
      lastName: from.lastName,
      email: from.email
    )

    nameLabel.stringValue = switch self.kind {
      case .replyInMessage:
        "\(senderName)"

      case .replyingInCompose:
        "Reply to \(senderName)"

      case .editingInCompose:
        "Edit Message"
    }

    // Update colors after setting senderNameForColor
    rectangleView.layer?.backgroundColor = rectangleColor.cgColor
    nameLabel.textColor = nameLabelColor
    layer?.backgroundColor = backgroundColor?.cgColor

    // Use display text which handles translations
    if let displayText = fullMessage.displayText, !displayText.isEmpty {
      messageLabel.stringValue = displayText
    } else if fullMessage.message.isSticker == true {
      messageLabel.stringValue = "🖼️ Sticker"
    } else if let _ = fullMessage.message.photoId {
      messageLabel.stringValue = "🖼️ Photo"
    } else if let _ = fullMessage.message.videoId {
      messageLabel.stringValue = "🎥 Video"
    } else if let _ = fullMessage.message.documentId {
      messageLabel.stringValue = "📄 Document"
    } else {
      messageLabel.stringValue = "Message"
    }
  }
}
