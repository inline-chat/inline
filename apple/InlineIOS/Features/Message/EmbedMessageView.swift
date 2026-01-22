import InlineKit
import InlineUI
import Translation
import UIKit

class EmbedMessageView: UIView {
  private enum Constants {
    static let cornerRadius: CGFloat = 8
    static let rectangleWidth: CGFloat = 4
    static let contentSpacing: CGFloat = 6
    static let verticalPadding: CGFloat = 4
    static let horizontalPadding: CGFloat = 6
    static let iconPointSizeMessage: CGFloat = 14
    static let iconPointSizeCompose: CGFloat = 17
    static let thumbnailSize: CGFloat = 32
    static let thumbnailCornerRadius: CGFloat = 4
    static let thumbnailOverlayPointSize: CGFloat = 16
  }

  enum Kind {
    case replyInMessage
    case replyingInCompose
    case editingInCompose
    case forwardingInCompose
  }

  enum Style {
    case replyBubble
    case compose
  }

  static let height: CGFloat = 42
  static let composeHeight: CGFloat = {
    let headerFont = UIFont.systemFont(ofSize: 17, weight: .medium)
    let messageFont = UIFont.systemFont(ofSize: 17)
    let spacing: CGFloat = 4
    let totalHeight = (Constants.verticalPadding * 2) + headerFont.lineHeight + spacing + messageFont.lineHeight
    return ceil(totalHeight)
  }()
  private var outgoing: Bool = false
  private var isOnlyEmoji: Bool = false
  private var kind: Kind = .replyInMessage
  private var style: Style = .replyBubble
  private var senderNameForColor: String?

  private lazy var headerLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  private lazy var messageLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.numberOfLines = 1
    return label
  }()

  private lazy var imageIconView: UIImageView = {
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFit
    imageView.setContentHuggingPriority(.required, for: .horizontal)
    imageView.translatesAutoresizingMaskIntoConstraints = false
    return imageView
  }()

  private lazy var messageStackView: UIStackView = {
    let stackView = UIStackView(arrangedSubviews: [imageIconView, messageLabel])
    stackView.axis = .horizontal
    stackView.spacing = 4
    stackView.alignment = .center
    stackView.translatesAutoresizingMaskIntoConstraints = false
    return stackView
  }()

  private lazy var rectangleView: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.layer.mask = CAShapeLayer()
    return view
  }()

  private lazy var thumbnailContainer: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.layer.cornerRadius = Constants.thumbnailCornerRadius
    view.layer.masksToBounds = true
    view.isHidden = true
    return view
  }()

  private lazy var thumbnailView: PlatformPhotoView = {
    let view = PlatformPhotoView()
    view.photoContentMode = .aspectFill
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var thumbnailOverlayView: UIImageView = {
    let imageView = UIImageView()
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFit
    imageView.tintColor = .white
    imageView.isHidden = true
    return imageView
  }()

  private var thumbnailWidthConstraint: NSLayoutConstraint?
  private var thumbnailHeightConstraint: NSLayoutConstraint?
  private var textLeadingToRectangleConstraint: NSLayoutConstraint?
  private var textLeadingToThumbnailConstraint: NSLayoutConstraint?
  private var headerToMessageConstraint: NSLayoutConstraint?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    setupLayer()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
    setupLayer()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateRectangleMask()
  }

  func showNotLoaded(
    kind: Kind,
    senderName: String = "User",
    outgoing: Bool,
    isOnlyEmoji: Bool,
    style: Style? = nil
  ) {
    self.kind = kind
    self.style = resolveStyle(for: kind, styleOverride: style)
    self.outgoing = outgoing
    self.isOnlyEmoji = isOnlyEmoji
    senderNameForColor = nil

    headerLabel.text = headerText(for: kind, senderName: senderName)
    let fallbackText = "Message not loaded"
    messageLabel.text = kind == .forwardingInCompose
      ? forwardDescription(for: senderName, messageText: fallbackText)
      : fallbackText

    let config = UIImage.SymbolConfiguration(pointSize: iconPointSize, weight: .medium)
    imageIconView.image = UIImage(systemName: "exclamationmark.circle", withConfiguration: config)
    imageIconView.isHidden = false

    updateThumbnail(photoInfo: nil, overlaySymbol: nil, reloadMessage: nil)
    applyAppearance()
  }

  func configure(
    embeddedMessage: EmbeddedMessage,
    kind: Kind = .replyInMessage,
    outgoing: Bool,
    isOnlyEmoji: Bool,
    style: Style? = nil,
    senderNameOverride: String? = nil
  ) {
    updateView(
      message: embeddedMessage.message,
      from: embeddedMessage.from,
      displayText: embeddedMessage.displayText,
      photoInfo: embeddedMessage.photoInfo,
      videoInfo: embeddedMessage.videoInfo,
      kind: kind,
      outgoing: outgoing,
      isOnlyEmoji: isOnlyEmoji,
      style: style,
      senderNameOverride: senderNameOverride
    )
  }

  func configure(
    fullMessage: FullMessage,
    kind: Kind,
    outgoing: Bool = false,
    isOnlyEmoji: Bool = false,
    style: Style? = nil,
    senderNameOverride: String? = nil
  ) {
    updateView(
      message: fullMessage.message,
      from: fullMessage.from,
      displayText: fullMessage.displayText,
      photoInfo: fullMessage.photoInfo,
      videoInfo: fullMessage.videoInfo,
      kind: kind,
      outgoing: outgoing,
      isOnlyEmoji: isOnlyEmoji,
      style: style,
      senderNameOverride: senderNameOverride
    )
  }
}

private extension EmbedMessageView {
  var cornerRadius: CGFloat {
    style == .replyBubble ? Constants.cornerRadius : 0
  }

  var iconPointSize: CGFloat {
    style == .replyBubble ? Constants.iconPointSizeMessage : Constants.iconPointSizeCompose
  }

  func resolveStyle(for kind: Kind, styleOverride: Style?) -> Style {
    if let styleOverride {
      return styleOverride
    }
    return kind == .replyInMessage ? .replyBubble : .compose
  }

  func setupViews() {
    addSubview(rectangleView)
    addSubview(thumbnailContainer)
    addSubview(headerLabel)
    addSubview(messageStackView)

    thumbnailContainer.addSubview(thumbnailView)
    thumbnailContainer.addSubview(thumbnailOverlayView)

    textLeadingToRectangleConstraint = headerLabel.leadingAnchor.constraint(
      equalTo: rectangleView.trailingAnchor,
      constant: Constants.contentSpacing
    )

    textLeadingToRectangleConstraint?.isActive = true

    thumbnailWidthConstraint = thumbnailContainer.widthAnchor.constraint(equalToConstant: 0)
    thumbnailHeightConstraint = thumbnailContainer.heightAnchor.constraint(equalToConstant: 0)

    headerToMessageConstraint = messageStackView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor)

    NSLayoutConstraint.activate([
      rectangleView.leadingAnchor.constraint(equalTo: leadingAnchor),
      rectangleView.widthAnchor.constraint(equalToConstant: Constants.rectangleWidth),
      rectangleView.topAnchor.constraint(equalTo: topAnchor),
      rectangleView.bottomAnchor.constraint(equalTo: bottomAnchor),

      thumbnailContainer.leadingAnchor.constraint(
        equalTo: rectangleView.trailingAnchor,
        constant: Constants.contentSpacing
      ),
      thumbnailContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
      thumbnailWidthConstraint!,
      thumbnailHeightConstraint!,

      thumbnailView.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor),
      thumbnailView.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor),
      thumbnailView.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor),
      thumbnailView.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor),

      thumbnailOverlayView.centerXAnchor.constraint(equalTo: thumbnailContainer.centerXAnchor),
      thumbnailOverlayView.centerYAnchor.constraint(equalTo: thumbnailContainer.centerYAnchor),

      headerLabel.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -Constants.horizontalPadding
      ),
      headerLabel.topAnchor.constraint(
        equalTo: topAnchor,
        constant: Constants.verticalPadding
      ),
      headerToMessageConstraint!,

      messageStackView.leadingAnchor.constraint(equalTo: headerLabel.leadingAnchor),
      messageStackView.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -Constants.horizontalPadding
      ),
      messageStackView.bottomAnchor.constraint(
        equalTo: bottomAnchor,
        constant: -Constants.verticalPadding
      ),
    ])
  }

  func setupLayer() {
    UIView.performWithoutAnimation {
      layer.cornerRadius = cornerRadius
    }
    layer.masksToBounds = true
  }

  func updateView(
    message: Message,
    from: User?,
    displayText: String?,
    photoInfo: PhotoInfo?,
    videoInfo: VideoInfo?,
    kind: Kind,
    outgoing: Bool,
    isOnlyEmoji: Bool,
    style: Style?,
    senderNameOverride: String?
  ) {
    self.kind = kind
    self.style = resolveStyle(for: kind, styleOverride: style)
    self.outgoing = outgoing
    self.isOnlyEmoji = isOnlyEmoji

    let senderName = senderNameOverride ?? from?.shortDisplayName ?? "User"
    senderNameForColor = AvatarColorUtility.formatNameForHashing(
      firstName: from?.firstName,
      lastName: from?.lastName,
      email: from?.email
    )

    headerLabel.text = headerText(for: kind, senderName: senderName)
    messageLabel.text = messageContent(
      for: message,
      displayText: displayText,
      senderName: senderName,
      kind: kind
    )

    updateIcon(for: message)

    let previewPhoto = photoInfo ?? videoInfo?.thumbnail
    let overlaySymbol = videoInfo != nil ? "play.circle.fill" : nil
    updateThumbnail(photoInfo: previewPhoto, overlaySymbol: overlaySymbol, reloadMessage: message)

    applyAppearance()
  }

  func headerText(for kind: Kind, senderName: String) -> String {
    switch kind {
    case .replyInMessage:
      return senderName
    case .replyingInCompose:
      return "Replying to \(senderName)"
    case .editingInCompose:
      return "Editing message"
    case .forwardingInCompose:
      return "Forward Message"
    }
  }

  func messageContent(
    for message: Message,
    displayText: String?,
    senderName: String,
    kind: Kind
  ) -> String {
    let resolvedText = (displayText ?? message.text)?.replacingOccurrences(of: "\n", with: " ")

    let baseContent: String
    if message.hasUnsupportedTypes {
      baseContent = "Unsupported message"
    } else if message.isSticker == true {
      baseContent = "Sticker"
    } else if message.hasVideo {
      if message.hasText, let resolvedText {
        baseContent = resolvedText
      } else {
        baseContent = "Video"
      }
    } else if message.documentId != nil {
      if message.hasText, let resolvedText {
        baseContent = resolvedText
      } else {
        baseContent = "Document"
      }
    } else if message.hasPhoto {
      if message.hasText, let resolvedText {
        baseContent = resolvedText
      } else {
        baseContent = "Photo"
      }
    } else if message.hasText, let resolvedText {
      baseContent = resolvedText
    } else {
      baseContent = "Message"
    }

    if kind == .forwardingInCompose {
      return forwardDescription(for: senderName, messageText: baseContent)
    }
    return baseContent
  }

  func forwardDescription(for senderName: String, messageText: String) -> String {
    "\(senderName): \(messageText)"
  }

  func updateIcon(for message: Message) {
    if message.hasUnsupportedTypes {
      imageIconView.isHidden = true
      return
    }

    let config = UIImage.SymbolConfiguration(pointSize: iconPointSize, weight: .medium)

    if message.isSticker == true {
      imageIconView.image = UIImage(systemName: "face.smiling", withConfiguration: config)
      imageIconView.isHidden = false
      return
    }

    if message.documentId != nil {
      imageIconView.image = UIImage(systemName: "document.fill", withConfiguration: config)
      imageIconView.isHidden = false
      return
    }

    imageIconView.isHidden = true
  }

  func updateThumbnail(
    photoInfo: PhotoInfo?,
    overlaySymbol: String?,
    reloadMessage: Message?
  ) {
    if let photoInfo {
      thumbnailContainer.isHidden = false
      thumbnailWidthConstraint?.constant = Constants.thumbnailSize
      thumbnailHeightConstraint?.constant = Constants.thumbnailSize
      thumbnailView.setPhoto(photoInfo, reloadMessageOnFinish: reloadMessage)
      updateThumbnailOverlay(symbol: overlaySymbol)
      updateTextLeading(useThumbnail: true)
      return
    }

    thumbnailContainer.isHidden = true
    thumbnailWidthConstraint?.constant = 0
    thumbnailHeightConstraint?.constant = 0
    thumbnailView.setPhoto(nil)
    updateThumbnailOverlay(symbol: nil)
    updateTextLeading(useThumbnail: false)
  }

  func updateThumbnailOverlay(symbol: String?) {
    if let symbol {
      let config = UIImage.SymbolConfiguration(
        pointSize: Constants.thumbnailOverlayPointSize,
        weight: .semibold
      )
      thumbnailOverlayView.image = UIImage(systemName: symbol, withConfiguration: config)
      thumbnailOverlayView.isHidden = false
    } else {
      thumbnailOverlayView.isHidden = true
      thumbnailOverlayView.image = nil
    }
  }

  func updateTextLeading(useThumbnail: Bool) {
    if useThumbnail {
      textLeadingToRectangleConstraint?.isActive = false
      if textLeadingToThumbnailConstraint == nil {
        textLeadingToThumbnailConstraint = headerLabel.leadingAnchor.constraint(
          equalTo: thumbnailContainer.trailingAnchor,
          constant: Constants.contentSpacing
        )
      }
      textLeadingToThumbnailConstraint?.isActive = true
    } else {
      textLeadingToThumbnailConstraint?.isActive = false
      textLeadingToRectangleConstraint?.isActive = true
    }
  }

  func applyAppearance() {
    headerLabel.font = style == .replyBubble
      ? .systemFont(ofSize: 14, weight: .bold)
      : .systemFont(ofSize: 17, weight: .medium)

    messageLabel.font = style == .replyBubble
      ? .systemFont(ofSize: 14)
      : .systemFont(ofSize: 17)

    headerToMessageConstraint?.constant = style == .replyBubble ? 0 : 4

    layer.cornerRadius = cornerRadius
    rectangleView.isHidden = style != .replyBubble
    updateColors()
    setNeedsLayout()
  }

  func updateColors() {
    let senderColor: UIColor = {
      if let senderNameForColor {
        return AvatarColorUtility.uiColorFor(name: senderNameForColor)
      }
      return ThemeManager.shared.selected.accent
    }()

    switch style {
    case .replyBubble:
      let useWhite = outgoing && !isOnlyEmoji
      let textColor: UIColor = useWhite ? .white : .label
      let headerColor: UIColor = useWhite ? .white : senderColor
      let rectangleColor: UIColor = useWhite ? .white : senderColor
      let bgAlpha: CGFloat = useWhite ? 0.13 : 0.08

      backgroundColor = useWhite ? .white.withAlphaComponent(bgAlpha)
        : headerColor.withAlphaComponent(bgAlpha)

      headerLabel.textColor = headerColor
      messageLabel.textColor = textColor
      rectangleView.backgroundColor = rectangleColor
      imageIconView.tintColor = textColor

    case .compose:
      let accentColor = ThemeManager.shared.selected.accent

      backgroundColor = .clear
      headerLabel.textColor = accentColor
      messageLabel.textColor = .secondaryLabel
      rectangleView.backgroundColor = accentColor
      imageIconView.tintColor = .secondaryLabel
    }
  }

  func updateRectangleMask() {
    let path = UIBezierPath(
      roundedRect: rectangleView.bounds,
      byRoundingCorners: [.topLeft, .bottomLeft],
      cornerRadii: CGSize(width: cornerRadius, height: cornerRadius)
    )

    if let mask = rectangleView.layer.mask as? CAShapeLayer {
      mask.path = path.cgPath
    }
  }
}
