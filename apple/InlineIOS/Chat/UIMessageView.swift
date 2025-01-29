import InlineKit
import SwiftUI
import UIKit

class UIMessageView: UIView {
  // MARK: - Properties

  private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
  private var links: [(range: NSRange, url: URL)] = []

  private static let attributedCache: NSCache<NSString, NSAttributedString> = {
    let cache = NSCache<NSString, NSAttributedString>()
    cache.countLimit = 100
    return cache
  }()

  var linkTapHandler: ((URL) -> Void)?
  private var interaction: UIContextMenuInteraction?

  private lazy var messageLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.backgroundColor = .clear
    label.textAlignment = .natural
    label.font = .systemFont(ofSize: 17)
    label.textColor = textColor
    label.numberOfLines = 0
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  private let bubbleView: UIView = {
    let view = UIView()
    view.layer.cornerRadius = 19
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  lazy var embedView: EmbedMessageView = {
    let view = EmbedMessageView()

    view.translatesAutoresizingMaskIntoConstraints = false

    return view
  }()

  var fullMessage: FullMessage

  var outgoing: Bool {
    fullMessage.message.out == true
  }

  private var bubbleColor: UIColor {
    outgoing ? ColorManager.shared.selectedColor : UIColor.systemGray5.withAlphaComponent(0.5)
  }

  private var textColor: UIColor {
    outgoing ? .white : .label
  }

  private var message: Message {
    fullMessage.message
  }

  private let metadataView: MessageTimeAndStatus

  private var multiline: Bool {
    guard let text = message.text else { return false }
    return text.count > 24 || text.contains("\n")
  }

  private var labelVerticalPadding: CGFloat = 9.0
  private var labelHorizantalPadding: CGFloat = 12.0

  // MARK: - Initialization

  init(fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    metadataView = MessageTimeAndStatus(fullMessage)
    metadataView.translatesAutoresizingMaskIntoConstraints = false
    super.init(frame: .zero)

    handleLinkTap()

    setupViews()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func handleLinkTap() {
    linkTapHandler = { url in
      UIApplication.shared.open(url)
    }
  }

  private func setupViews() {
    addSubview(bubbleView)
    bubbleView.addSubview(metadataView)
    bubbleView.addSubview(messageLabel)

    if message.repliedToMessageId != nil {
      bubbleView.addSubview(embedView)

      if let repliedMessage = fullMessage.repliedToMessage {
        embedView.configure(
          message: repliedMessage,
          senderName: Auth.shared.getCurrentUserId() == fullMessage.repliedToMessage?.fromId ? "You" : fullMessage
            .replyToMessageSender?.firstName ?? "",
          outgoing: outgoing
        )
      }
    }
    addGestureRecognizer()
    setupAppearance()
    setupConstraints()
    setupContextMenu()
  }

  private func addGestureRecognizer() {
    bubbleView.isUserInteractionEnabled = true
    messageLabel.isUserInteractionEnabled = true

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    bubbleView.addGestureRecognizer(tapGesture)
  }

  private func setupConstraints() {
    let messageConstraints =
      multiline ? setupMultilineMessageConstraints() : setupOneLineMessageConstraints()

    NSLayoutConstraint.activate(
      [
        //  Bubble view constraints
        bubbleView.topAnchor.constraint(equalTo: topAnchor),
        bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor),
        bubbleView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
      ] + messageConstraints
    )

    if outgoing {
      bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).isActive = true
    } else {
      bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).isActive = true
    }
  }

  private func setupMultilineMessageConstraints() -> [NSLayoutConstraint] {
    let noEmbed = [
      messageLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: labelVerticalPadding),
      messageLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: labelHorizantalPadding),
      messageLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -labelHorizantalPadding),

      metadataView.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: labelVerticalPadding),
      metadataView.leadingAnchor.constraint(
        greaterThanOrEqualTo: bubbleView.leadingAnchor, constant: 14
      ),
      metadataView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
      metadataView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -14),
    ]
    let withEmbed = [
      embedView.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: labelVerticalPadding),
      embedView.leadingAnchor.constraint(equalTo: messageLabel.leadingAnchor),
      embedView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
      embedView.bottomAnchor.constraint(equalTo: messageLabel.topAnchor, constant: -labelVerticalPadding),

      messageLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: labelHorizantalPadding),
      messageLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -labelHorizantalPadding),

      metadataView.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: labelVerticalPadding),
      metadataView.leadingAnchor.constraint(
        greaterThanOrEqualTo: bubbleView.leadingAnchor, constant: 14
      ),
      metadataView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
      metadataView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -14),
    ]
    return message.repliedToMessageId != nil ? withEmbed : noEmbed
  }

  private func setupOneLineMessageConstraints() -> [NSLayoutConstraint] {
    let noEmbed = [
      messageLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: labelVerticalPadding),
      messageLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: labelHorizantalPadding),
      messageLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -labelVerticalPadding),

      metadataView.leadingAnchor.constraint(equalTo: messageLabel.trailingAnchor, constant: 8),
      metadataView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
      metadataView.centerYAnchor.constraint(equalTo: messageLabel.centerYAnchor),
    ]
    let withEmbed = [
      embedView.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: labelVerticalPadding),
      embedView.leadingAnchor.constraint(equalTo: messageLabel.leadingAnchor),
      embedView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
      embedView.bottomAnchor.constraint(equalTo: messageLabel.topAnchor, constant: -labelVerticalPadding),

      messageLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: labelHorizantalPadding),
      messageLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -labelVerticalPadding),

      metadataView.leadingAnchor.constraint(equalTo: messageLabel.trailingAnchor, constant: 8),
      metadataView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
      metadataView.centerYAnchor.constraint(equalTo: messageLabel.centerYAnchor),
    ]

    return message.repliedToMessageId != nil ? withEmbed : noEmbed
  }

  private func setupAppearance() {
    guard let text = message.text else { return }

    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: UIFont.systemFont(ofSize: 17),
        .foregroundColor: textColor,
      ]
    )

    detectAndStyleLinks(in: text, attributedString: attributedString)

    cacheLink(attributedString, key: text)

    messageLabel.attributedText = attributedString
    bubbleView.backgroundColor = bubbleColor
  }

  private func cacheLink(_ attributedString: NSMutableAttributedString, key: String) {
    Self.attributedCache.setObject(attributedString, forKey: key as NSString)
  }

  private func detectAndStyleLinks(in text: String, attributedString: NSMutableAttributedString) {
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
      let nsString = text as NSString
      let range = NSRange(location: 0, length: nsString.length)
      let matches = detector.matches(in: text, options: [], range: range)

      links = matches.compactMap { match in
        guard let url = match.url else { return nil }

        let linkAttributes: [NSAttributedString.Key: Any] = [
          .foregroundColor: outgoing ? UIColor.white.withAlphaComponent(0.9) : .systemBlue,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        attributedString.addAttributes(linkAttributes, range: match.range)

        return (range: match.range, url: url)
      }
    }
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard !links.isEmpty else { return }
    print("handleTap called")

    let point = gesture.location(in: messageLabel)

    // Get tapped character index
    let textContainer = NSTextContainer(size: messageLabel.bounds.size)
    let layoutManager = NSLayoutManager()
    let textStorage = NSTextStorage(attributedString: messageLabel.attributedText ?? NSAttributedString())

    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)

    textContainer.lineFragmentPadding = 0
    textContainer.lineBreakMode = messageLabel.lineBreakMode
    textContainer.maximumNumberOfLines = messageLabel.numberOfLines

    let index = layoutManager.characterIndex(
      for: point,
      in: textContainer,
      fractionOfDistanceBetweenInsertionPoints: nil
    )

    // Check for tapped link
    for link in links where NSLocationInRange(index, link.range) {
      print("Link tapped: \(link.url)")
      linkTapHandler?(link.url)
      break
    }
  }

  private func setupContextMenu() {
    let interaction = UIContextMenuInteraction(delegate: self)
    self.interaction = interaction
    bubbleView.addInteraction(interaction)
  }
}

// MARK: - Context Menu

extension UIMessageView: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      guard let self else { return nil }

      let copyAction = UIAction(title: "Copy") { _ in
        UIPasteboard.general.string = self.message.text
      }

      var actions: [UIAction] = [copyAction]

      let replyAction = UIAction(title: "Reply") { _ in
        print("REPLY \(self.message.id)")
        ChatState.shared.setReplyingMessageId(peer: self.message.peerId, id: self.message.id)
      }
      actions.append(replyAction)

      if let url = getURLAtLocation(location) {
        let openLinkAction = UIAction(title: "Open Link") { _ in
          self.linkTapHandler?(url)
        }
        actions.append(openLinkAction)
      }

      return UIMenu(children: actions)
    }
  }

  private func getURLAtLocation(_ location: CGPoint) -> URL? {
    guard !links.isEmpty else { return nil }

    let textContainer = NSTextContainer(size: messageLabel.bounds.size)
    let layoutManager = NSLayoutManager()
    let textStorage = NSTextStorage(attributedString: messageLabel.attributedText ?? NSAttributedString())

    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)

    textContainer.lineFragmentPadding = 0
    textContainer.lineBreakMode = messageLabel.lineBreakMode
    textContainer.maximumNumberOfLines = messageLabel.numberOfLines

    let index = layoutManager.characterIndex(
      for: location,
      in: textContainer,
      fractionOfDistanceBetweenInsertionPoints: nil
    )

    for link in links where NSLocationInRange(index, link.range) {
      return link.url
    }

    return nil
  }

  static var contextMenuOpen: Bool = false
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    Self.contextMenuOpen = true
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    Self.contextMenuOpen = false
  }
}
