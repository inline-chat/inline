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
    case pinnedInHeader
  }

  private var kind: Kind = .replyInMessage
  private var style: EmbeddedMessageStyle

  private var message: Message?
  private var relatedMessage: Message?
  private var senderNameForColor: String?
  private var simplePhotoView: SimplePhotoView?
  private var textLeadingConstraint: NSLayoutConstraint?
  private var nameTrailingConstraint: NSLayoutConstraint?
  private var messageTrailingConstraint: NSLayoutConstraint?
  private var rectangleWidthConstraint: NSLayoutConstraint?
  private var heightConstraint: NSLayoutConstraint?
  private var nameLabelHeightConstraint: NSLayoutConstraint?
  private var nameLabelTopConstraint: NSLayoutConstraint?
  private var messageLabelBottomConstraint: NSLayoutConstraint?
  private var photoConstraints: [NSLayoutConstraint] = []

  var showsBackground: Bool = true {
    didSet {
      applyBackgroundAppearance()
    }
  }

  var showsLeadingBar: Bool = true {
    didSet {
      applyLeadingBarAppearance()
    }
  }

  var textHorizontalPadding: CGFloat = Constants.horizontalPadding {
    didSet {
      textLeadingPadding = textHorizontalPadding
      textTrailingPadding = textHorizontalPadding
    }
  }

  var textLeadingPadding: CGFloat = Constants.horizontalPadding {
    didSet {
      applyTextPadding()
    }
  }

  var textTrailingPadding: CGFloat = Constants.horizontalPadding {
    didSet {
      applyTextPadding()
    }
  }

  private var cornerRadius: CGFloat {
    switch kind {
      case .replyInMessage, .pinnedInHeader:
        8
      default:
        0
    }
  }

  private var senderFont: NSFont {
    let weight: NSFont.Weight = kind == .pinnedInHeader ? .regular : .semibold
    return .systemFont(ofSize: 12, weight: weight)
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
      return shouldUseSenderColor ? senderColor : NSColor.controlAccentColor
    } else {
      return NSColor.white
    }
  }

  private var nameLabelColor: NSColor {
    if style == .colored {
      if kind == .pinnedInHeader {
        return textColor
      }
      return shouldUseSenderColor ? senderColor : NSColor.controlAccentColor
    } else {
      return NSColor.white
    }
  }

  private var backgroundColor: NSColor? {
    guard kind == .replyInMessage || kind == .pinnedInHeader else { return nil }

    if style == .colored {
      let baseColor = shouldUseSenderColor ? senderColor : NSColor.controlAccentColor
      return baseColor.withAlphaComponent(0.08)
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
    layer?.masksToBounds = true

    translatesAutoresizingMaskIntoConstraints = false

    addSubview(rectangleView)
    addSubview(nameLabel)
    addSubview(messageLabel)

    textLeadingConstraint = nameLabel.leadingAnchor.constraint(
      equalTo: rectangleView.trailingAnchor, constant: Constants.contentSpacing
    )
    rectangleWidthConstraint = rectangleView.widthAnchor.constraint(equalToConstant: Constants.rectangleWidth)

    heightConstraint = heightAnchor.constraint(equalToConstant: Constants.height)
    nameLabelHeightConstraint = nameLabel.heightAnchor.constraint(equalToConstant: Theme.messageNameLabelHeight)
    nameLabelTopConstraint = nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: Constants.verticalPadding)
    messageLabelBottomConstraint = messageLabel.bottomAnchor.constraint(
      equalTo: bottomAnchor, constant: -Constants.verticalPadding
    )

    nameTrailingConstraint = nameLabel.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -Constants.horizontalPadding
    )
    messageTrailingConstraint = messageLabel.trailingAnchor.constraint(
      equalTo: trailingAnchor, constant: -Constants.horizontalPadding
    )

    NSLayoutConstraint.activate([
      // Height
      heightConstraint!,

      // Rectangle view
      rectangleView.leadingAnchor.constraint(equalTo: leadingAnchor),
      rectangleWidthConstraint!,
      rectangleView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
      rectangleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),

      // Name label
      textLeadingConstraint!,
      nameTrailingConstraint!,
      nameLabelTopConstraint!,
      nameLabelHeightConstraint!,

      // Message label
      messageLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
      messageTrailingConstraint!,
      messageLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor),
      messageLabelBottomConstraint!,
    ])

    let clickGesture = NSClickGestureRecognizer(
      target: self,
      action: #selector(handleTap)
    )
    addGestureRecognizer(clickGesture)

    applyBackgroundAppearance()
    applyLeadingBarAppearance()
    applyTextPadding()
  }

  func setCollapsed(_ collapsed: Bool) {
    let height = collapsed ? 0 : Constants.height
    let nameHeight = collapsed ? 0 : Theme.messageNameLabelHeight
    let verticalPadding = collapsed ? 0 : Constants.verticalPadding

    heightConstraint?.constant = height
    nameLabelHeightConstraint?.constant = nameHeight
    nameLabelTopConstraint?.constant = verticalPadding
    messageLabelBottomConstraint?.constant = -verticalPadding
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

      case .pinnedInHeader:
        "Pinned Message"
    }

    // Update visuals after setting senderNameForColor
    nameLabel.font = senderFont
    rectangleView.layer?.backgroundColor = rectangleColor.cgColor
    nameLabel.textColor = nameLabelColor
    applyBackgroundAppearance()

    // Handle photo if available
    let previewPhoto = photoInfo ?? videoInfo?.thumbnail
    let overlaySymbol = videoInfo != nil ? "play.circle.fill" : nil
    updatePhotoView(photoInfo: previewPhoto, overlaySymbol: overlaySymbol)

    if kind == .forwardingInCompose {
      messageLabel.stringValue = forwardDescription(for: senderName, messageText: messageContent)
    } else if kind == .pinnedInHeader {
      messageLabel.stringValue = messageContent
    } else {
      messageLabel.stringValue = messageContent
    }
  }

  func showNotLoaded(kind: Kind, senderName: String? = nil, messageText: String) {
    self.kind = kind
    self.message = nil
    senderNameForColor = senderName

    let resolvedSender = senderName ?? "User"

    nameLabel.stringValue = switch kind {
      case .replyInMessage:
        resolvedSender
      case .replyingInCompose:
        "Reply to \(resolvedSender)"
      case .editingInCompose:
        "Edit Message"
      case .forwardingInCompose:
        "Forward Message"
      case .pinnedInHeader:
        "Pinned Message"
    }

    if kind == .forwardingInCompose {
      messageLabel.stringValue = forwardDescription(for: resolvedSender, messageText: messageText)
    } else {
      messageLabel.stringValue = messageText
    }

    updatePhotoView(photoInfo: nil, overlaySymbol: nil)

    nameLabel.font = senderFont
    rectangleView.layer?.backgroundColor = rectangleColor.cgColor
    nameLabel.textColor = nameLabelColor
    applyBackgroundAppearance()
  }

  private func applyBackgroundAppearance() {
    layer?.backgroundColor = showsBackground ? backgroundColor?.cgColor : nil
    layer?.cornerRadius = showsBackground ? cornerRadius : 0
  }

  private func applyLeadingBarAppearance() {
    let leadingPadding = showsLeadingBar ? Constants.contentSpacing : textLeadingPadding
    rectangleView.isHidden = !showsLeadingBar
    rectangleWidthConstraint?.constant = showsLeadingBar ? Constants.rectangleWidth : 0
    textLeadingConstraint?.constant = leadingPadding
  }

  private func applyTextPadding() {
    nameTrailingConstraint?.constant = -textTrailingPadding
    messageTrailingConstraint?.constant = -textTrailingPadding
    if !showsLeadingBar {
      textLeadingConstraint?.constant = textLeadingPadding
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
