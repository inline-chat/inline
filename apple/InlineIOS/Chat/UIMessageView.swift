import InlineKit
import Nuke
import NukeUI
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

  // MARK: - UI Components

  private lazy var containerStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = labelVerticalPadding
    stack.alignment = .fill
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var singleLineContainer: UIStackView = {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.spacing = 8
    stack.alignment = .center
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var multiLineContainer: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 10
    stack.alignment = .fill
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var messageLabel: UILabel = {
    let label = UILabel()
    label.backgroundColor = .clear
    label.textAlignment = .natural
    label.font = .systemFont(ofSize: 18)
    label.textColor = textColor
    label.numberOfLines = 0
//    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
//    label.setContentCompressionResistancePriority(.required, for: .horizontal)
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
    return view
  }()

  private lazy var photoView: PhotoView = {
    let view = PhotoView(fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  var fullMessage: FullMessage
  private let metadataView: MessageTimeAndStatus

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

  private var isMultiline: Bool {
    if let file = fullMessage.file,
       let width = file.width,
       let height = file.height,
       height > width && width < 250
    {
      return true
    }

    guard let text = message.text else { return false }
    return text.count > 24 || text.contains("\n")
  }

  var isJustFile: Bool {
    if fullMessage.file != nil, fullMessage.message.text?.isEmpty == true, fullMessage.repliedToMessage == nil {
      true
    } else {
      false
    }
  }

  private let labelVerticalPadding: CGFloat = 9.0
  private let labelHorizantalPadding: CGFloat = 12.0

  // MARK: - Initialization

  init(fullMessage: FullMessage) {
    self.fullMessage = fullMessage
    metadataView = MessageTimeAndStatus(fullMessage)
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
    bubbleView.addSubview(containerStack)

    setupReplyViewIfNeeded()
    setupFileViewIfNeeded()
    setupMessageContainer()

    addGestureRecognizer()
    setupAppearance()
    setupConstraints()
    setupContextMenu()
  }

  private func setupReplyViewIfNeeded() {
    guard message.repliedToMessageId != nil else { return }

    containerStack.addArrangedSubview(embedView)

    if let repliedMessage = fullMessage.repliedToMessage {
      let senderName = Auth.shared.getCurrentUserId() == fullMessage.repliedToMessage?.fromId ?
        "You" : fullMessage.replyToMessageSender?.firstName ?? ""
      embedView.configure(
        message: repliedMessage,
        senderName: senderName,
        outgoing: outgoing
      )
    }
  }

  private func setupFileViewIfNeeded() {
    guard fullMessage.file != nil else { return }

    containerStack.addArrangedSubview(photoView)
  }

  private func setupMessageContainer() {
    if isMultiline {
      multiLineContainer.addArrangedSubview(messageLabel)
      let metadataContainer = UIStackView()
      metadataContainer.axis = .horizontal
      metadataContainer.addArrangedSubview(UIView()) // Spacer
      metadataContainer.addArrangedSubview(metadataView)
      if !isJustFile {
        multiLineContainer.addArrangedSubview(metadataContainer)
      }
      containerStack.addArrangedSubview(multiLineContainer)
    } else {
      singleLineContainer.addArrangedSubview(messageLabel)
      if !isJustFile {
        singleLineContainer.addArrangedSubview(metadataView)
      }
      containerStack.addArrangedSubview(singleLineContainer)
    }
  }

  private func addGestureRecognizer() {
    bubbleView.isUserInteractionEnabled = true
    messageLabel.isUserInteractionEnabled = true

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    bubbleView.addGestureRecognizer(tapGesture)
  }

  private func setupConstraints() {
    NSLayoutConstraint.activate([
      bubbleView.topAnchor.constraint(equalTo: topAnchor),
      bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor),
      bubbleView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),

      containerStack.topAnchor.constraint(
        equalTo: bubbleView.topAnchor,
        constant: isJustFile ? 2 : labelVerticalPadding
      ),
      containerStack.leadingAnchor.constraint(
        equalTo: bubbleView.leadingAnchor,
        constant: isJustFile ? 2 : labelHorizantalPadding
      ),
      containerStack.trailingAnchor.constraint(
        equalTo: bubbleView.trailingAnchor,
        constant: isJustFile ? -2 : -labelHorizantalPadding
      ),
      containerStack.bottomAnchor.constraint(
        equalTo: bubbleView.bottomAnchor,
        constant: isJustFile ? 6 : isMultiline ? -14 : -labelVerticalPadding
      ).withPriority(.defaultHigh),
    ])
    if outgoing {
      bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).isActive = true
    } else {
      bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).isActive = true
    }
  }

  private func setupAppearance() {
    bubbleView.backgroundColor = bubbleColor
    guard let text = message.text else { return }

    if let cachedString = Self.attributedCache.object(forKey: text as NSString) {
      messageLabel.attributedText = cachedString

      return
    }

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

    let point = gesture.location(in: messageLabel)

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

    for link in links where NSLocationInRange(index, link.range) {
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
        UIPasteboard.general.string = "\(self.message.messageId) \(self.message.chatId)"

        // UIPasteboard.general.string = self.message.text
      }

      var actions: [UIAction] = [copyAction]

      let replyAction = UIAction(title: "Reply") { _ in
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
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    Self.contextMenuOpen = true
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willEndFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    Self.contextMenuOpen = false
  }
}

// Add this extension to help with constraint priorities
extension NSLayoutConstraint {
  func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
    self.priority = priority
    return self
  }
}
