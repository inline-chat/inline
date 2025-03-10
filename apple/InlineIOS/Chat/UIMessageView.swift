import Auth
import ContextMenuAuxiliaryPreview
import GRDB
import InlineKit
import Logger
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
    cache.countLimit = 1_000
    return cache
  }()

  var linkTapHandler: ((URL) -> Void)?
  private var interaction: UIContextMenuInteraction?
  private var contextMenuManager: ContextMenuManager?

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

    return label
  }()

  private lazy var unsupportedLabel: UILabel = {
    let label = UILabel()
    label.text = "Unsupported message"
    label.backgroundColor = .clear
    label.textAlignment = .natural
    label.font = .italicSystemFont(ofSize: 18)
    label.textColor = textColor.withAlphaComponent(0.9)
    label.numberOfLines = 0

    return label
  }()

  private let bubbleView: UIView = {
    let view = UIView()
    UIView.performWithoutAnimation {
      view.layer.cornerRadius = 19
    }
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  lazy var embedView: EmbedMessageView = {
    let view = EmbedMessageView()
    return view
  }()

  lazy var attachmentView: MessageAttachmentEmbed = {
    let view = MessageAttachmentEmbed()
    return view
  }()

  private lazy var photoView: PhotoView = {
    let view = PhotoView(fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var newPhotoView: NewPhotoView = {
    let view = NewPhotoView(fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  var fullMessage: FullMessage
  let spaceId: Int64
  private let metadataView: MessageTimeAndStatus

  private lazy var floatingMetadataView: FloatingMetadataView = {
    let view = FloatingMetadataView(fullMessage: fullMessage)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  var outgoing: Bool {
    fullMessage.message.out == true
  }

  private var bubbleColor: UIColor {
    if isEmojiOnlyMessage {
      UIColor.clear
    } else if outgoing {
      ColorManager.shared.selectedColor
    } else {
      ColorManager.shared.secondaryColor
    }
  }

  private var textColor: UIColor {
    outgoing ? .white : .label
  }

  private var message: Message {
    fullMessage.message
  }

  var isEmojiOnlyMessage: Bool {
    guard let text = message.text else { return false }
    if text.containsOnlyEmojis {
      return true
    } else {
      return false
    }
  }

  var isSingleEmojiMessage: Bool {
    guard let text = message.text else { return false }
    return isEmojiOnlyMessage && text.count == 1
  }

  var isTripleEmojiMessage: Bool {
    guard let text = message.text else { return false }
    return isEmojiOnlyMessage && text.count <= 3
  }

  private var isMultiline: Bool {
    if message.hasUnsupportedTypes {
      return false
    }
    if fullMessage.file != nil {
      return true
    }

    if fullMessage.photoInfo != nil {
      return true
    }

    if !fullMessage.attachments.isEmpty {
      return true
    }
    guard let text = message.text else { return false }
    return text.count > 24 || text.contains("\n") || !fullMessage.reactions.isEmpty || text.containsEmoji
  }

  private let labelVerticalPadding: CGFloat = 9.0
  private let labelHorizantalPadding: CGFloat = 12.0

  // MARK: - Initialization

  init(fullMessage: FullMessage, spaceId: Int64) {
    self.fullMessage = fullMessage
    self.spaceId = spaceId

    // TODO: move to lazy var
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
    setupPhotoViewIfNeeded()
    setupMessageContainer()

    if message.hasFile, !message.hasText {
      addFloatingMetadata()
    }

    addGestureRecognizer()
    setupAppearance()
    setupConstraints()
    setupContextMenu()
  }

  private func addFloatingMetadata() {
    bubbleView.addSubview(floatingMetadataView)

    let padding: CGFloat = 12

    NSLayoutConstraint.activate([
      floatingMetadataView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -padding),
      floatingMetadataView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -padding),
    ])
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

  private func setupPhotoViewIfNeeded() {
    guard fullMessage.photoInfo != nil else { return }

    containerStack.addArrangedSubview(newPhotoView)
  }

  private func setupMessageContainer() {
    if isMultiline {
      setupMultilineMessage()
    } else {
      setupSingleLineMessage()
    }
  }

  private func setupMultilineMessage() {
    if message.hasFile, message.hasText {
      let innerContainer = UIStackView()
      innerContainer.axis = .vertical
      innerContainer.translatesAutoresizingMaskIntoConstraints = false
      innerContainer.layoutMargins = UIEdgeInsets(
        top: 0,
        left: StackPadding.leading,
        bottom: 0,
        right: StackPadding.trailing
      )
      innerContainer.spacing = 10
      innerContainer.isLayoutMarginsRelativeArrangement = true
      innerContainer.insetsLayoutMarginsFromSafeArea = false

      innerContainer.addArrangedSubview(messageLabel)

      if !fullMessage.attachments.isEmpty {
        setupAttachmentView()
        innerContainer.addArrangedSubview(attachmentView)
      }

      let metadataContainer = UIStackView()
      metadataContainer.axis = .horizontal
      metadataContainer.translatesAutoresizingMaskIntoConstraints = false
      metadataContainer.addArrangedSubview(UIView())
      metadataContainer.addArrangedSubview(metadataView)
      innerContainer.addArrangedSubview(metadataContainer)

      containerStack.addArrangedSubview(innerContainer)
    } else {
      multiLineContainer.addArrangedSubview(messageLabel)

      if !fullMessage.attachments.isEmpty {
        setupAttachmentView()
        multiLineContainer.addArrangedSubview(attachmentView)
      }

      if !message.hasFile || message.hasText {
        setupMultilineMetadata()
        containerStack.addArrangedSubview(multiLineContainer)
        return
      }
    }
  }

  private func setupMultilineMetadata() {
    let metadataContainer = UIStackView()
    metadataContainer.axis = .horizontal
    metadataContainer.addArrangedSubview(UIView()) // Spacer
    metadataContainer.addArrangedSubview(isEmojiOnlyMessage ? floatingMetadataView : metadataView)
    multiLineContainer.addArrangedSubview(metadataContainer)
  }

  private func setupSingleLineMessage() {
    if message.hasUnsupportedTypes {
      singleLineContainer.addArrangedSubview(unsupportedLabel)
    } else {
      singleLineContainer.addArrangedSubview(messageLabel)
    }
    singleLineContainer.addArrangedSubview(metadataView)
    containerStack.addArrangedSubview(singleLineContainer)
  }

  private func addGestureRecognizer() {
    bubbleView.isUserInteractionEnabled = true
    messageLabel.isUserInteractionEnabled = true

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    bubbleView.addGestureRecognizer(tapGesture)
  }

  enum StackPadding {
    static let top: CGFloat = 9
    static let leading: CGFloat = 12
    static let bottom: CGFloat = 9
    static let trailing: CGFloat = 12
  }

  private func setupConstraints() {
    let padding = NSDirectionalEdgeInsets(
      top: isEmojiOnlyMessage ? 6 : StackPadding.top,
      leading: isEmojiOnlyMessage ? 0 : StackPadding.leading,
      bottom: isEmojiOnlyMessage ? 6 : isMultiline ? 14 : StackPadding.bottom,
      trailing: isEmojiOnlyMessage ? 0 : StackPadding.trailing
    )

    let baseConstraints: [NSLayoutConstraint] = [
      bubbleView.topAnchor.constraint(equalTo: topAnchor),
      bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor),
      bubbleView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
    ]

    let withoutFileConstraints: [NSLayoutConstraint] = [
      containerStack.topAnchor.constraint(
        equalTo: bubbleView.topAnchor,
        constant: padding.top
      ),
      containerStack.leadingAnchor.constraint(
        equalTo: bubbleView.leadingAnchor,
        constant: padding.leading
      ),
      containerStack.trailingAnchor.constraint(
        equalTo: bubbleView.trailingAnchor,
        constant: -padding.trailing
      ),
      containerStack.bottomAnchor.constraint(
        equalTo: bubbleView.bottomAnchor,
        constant: -padding.bottom
      ).withPriority(.defaultHigh),
    ]

    let withFileConstraints: [NSLayoutConstraint] = [
      containerStack.topAnchor.constraint(
        equalTo: bubbleView.topAnchor,
        constant: 0
      ),
      containerStack.leadingAnchor.constraint(
        equalTo: bubbleView.leadingAnchor,
        constant: 0
      ),
      containerStack.trailingAnchor.constraint(
        equalTo: bubbleView.trailingAnchor,
        constant: 0
      ),
      containerStack.bottomAnchor.constraint(
        equalTo: bubbleView.bottomAnchor,
        constant: 0
      ).withPriority(.defaultHigh),
    ]

    let withFileAndTextConstraints: [NSLayoutConstraint] = [
      containerStack.topAnchor.constraint(
        equalTo: bubbleView.topAnchor,
        constant: 0
      ),
      containerStack.leadingAnchor.constraint(
        equalTo: bubbleView.leadingAnchor,
        constant: 0
      ),
      containerStack.trailingAnchor.constraint(
        equalTo: bubbleView.trailingAnchor,
        constant: 0
      ),
      containerStack.bottomAnchor.constraint(
        equalTo: bubbleView.bottomAnchor,
        constant: -padding.bottom
      ).withPriority(.defaultHigh),
    ]

    let constraints: [NSLayoutConstraint] = switch (message.hasFile, message.hasText) {
    case (true, false):
      // File only
      withFileConstraints
    case (true, true):
      // File with text
      withFileAndTextConstraints
    default:
      // Text only
      withoutFileConstraints
    }

    NSLayoutConstraint.activate(baseConstraints + constraints)

    if outgoing {
      bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8).isActive = true
    } else {
      bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8).isActive = true
    }
  }

  private func setupAppearance() {
    let cacheKey = "\(message.stableId)-\(message.text?.count ?? 0)-\(message.text?.hash ?? 0)"
    bubbleView.backgroundColor = bubbleColor

    guard let text = message.text else { return }
    if let cachedString = Self.attributedCache.object(forKey: NSString(string: cacheKey)) {
      messageLabel.attributedText = cachedString
      return
    }

    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: UIFont
          .systemFont(ofSize: isSingleEmojiMessage ? 120 : isTripleEmojiMessage ? 70 : isEmojiOnlyMessage ? 32 : 17),
        .foregroundColor: textColor,
      ]
    )

    detectAndStyleLinks(in: text, attributedString: attributedString)

    Self.attributedCache.setObject(attributedString, forKey: cacheKey as NSString)

    messageLabel.attributedText = attributedString
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

    contextMenuManager = ContextMenuManager(
      contextMenuInteraction: interaction,
      menuTargetView: self
    )
    contextMenuManager?.delegate = self
    contextMenuManager?.auxiliaryPreviewConfig = AuxiliaryPreviewConfig(
      verticalAnchorPosition: .automatic,
      horizontalAlignment: outgoing ? .targetTrailing : .targetLeading,
      preferredWidth: .none,
      preferredHeight: .none,
      marginInner: 10,
      marginOuter: 10,
      transitionConfigEntrance: .syncedToMenuEntranceTransition(),
      transitionExitPreset: .fade
    )

    bubbleView.addInteraction(interaction)
  }

  func extractListItems(from message: String) -> [String] {
    let pattern = #"^\s*-\s+(.*)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive]) else {
      return []
    }

    var items: [String] = []
    let nsString = message as NSString

    regex.enumerateMatches(in: message, options: [], range: NSRange(
      location: 0,
      length: message.utf16.count
    )) { match, _, _ in
      guard let match, match.numberOfRanges > 1 else { return }

      let contentRange = match.range(at: 1)
      if contentRange.location != NSNotFound {
        let content = nsString.substring(with: contentRange)
          .trimmingCharacters(in: .whitespacesAndNewlines)

        if !content.isEmpty {
          items.append(content)
        }
      }
    }

    return items
  }

  func createIssueFunc() {
    let items = extractListItems(from: message.text ?? "")
    Task { @MainActor in
      do {
        let result = try await ApiClient.shared.getIntegrations(userId: Auth.shared.getCurrentUserId() ?? 0)
        if !result.hasLinearConnected {
          ToastManager.shared.showToast(
            "Please connect Linear from Settings > Integrations",
            type: .info,
            systemImage: "link.circle"
          )
        } else {
          if items.count > 1 {
            ToastManager.shared.showToast(
              "Creating Linear issues...",
              type: .loading,
              systemImage: "circle.dotted"
            )

            for item in items {
              print("item is \(item)")
              do {
                _ = try await ApiClient.shared.createLinearIssue(
                  text: item,
                  messageId: self.message.messageId,
                  peerId: self.fullMessage.peerId,
                  chatId: self.message.chatId,
                  fromId: self.message.fromId
                )
              } catch {
                print("FAILED to create issue \(error)")
                ToastManager.shared.hideToast()
                ToastManager.shared.showToast(
                  "Failed to create issue",
                  type: .info,
                  systemImage: "xmark.circle.fill"
                )
              }
            }
            ToastManager.shared.showToast(
              "\(items.count) Issues created",
              type: .success,
              systemImage: "checkmark.circle.fill"
            )

          } else {
            ToastManager.shared.showToast(
              "Creating Linear issue...",
              type: .loading,
              systemImage: "circle.dotted"
            )

            do {
              let result = try await ApiClient.shared.createLinearIssue(
                text: self.message.text ?? "",
                messageId: self.message.messageId,
                peerId: self.fullMessage.peerId,
                chatId: self.message.chatId,
                fromId: self.message.fromId
              )
              ToastManager.shared.showToast(
                "Issue created",
                type: .success,
                systemImage: "checkmark.circle.fill",
                action: {
                  if let url = URL(string: result.link ?? "") {
                    UIApplication.shared.open(url)
                  }
                },
                actionTitle: "Open"
              )

            } catch {
              print("FAILED to create issue \(error)")
              ToastManager.shared.hideToast()
              ToastManager.shared.showToast(
                "Failed to create issue",
                type: .info,
                systemImage: "xmark.circle.fill"
              )
            }
          }
        }
      } catch {
        ToastManager.shared.hideToast()
        print("Failed to get integrations \(error)")
      }
    }
  }

  private func setupAttachmentView() {
    if let fullAttachment = fullMessage.attachments.first {
      let userName = Auth.shared.getCurrentUserId() == fullAttachment.user?.id ?
        "You" : fullAttachment.user?.firstName ?? ""
      attachmentView.configure(
        userName: userName,
        outgoing: outgoing,
        url: URL(string: fullAttachment.externalTask?.url ?? ""),
        issueIdentifier: fullAttachment.externalTask?.number,
        title: fullAttachment.externalTask?.title
      )
    }
  }

  private func showDeleteConfirmation() {
    guard let viewController = findViewController() else { return }

    let alert = UIAlertController(
      title: "Delete Message",
      message: "Are you sure you want to delete this message?",
      preferredStyle: .alert
    )

    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

    alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
      guard let self else { return }
      Task {
        let _ = Transactions.shared.mutate(
          transaction: .deleteMessage(
            .init(
              messageIds: [self.message.messageId],
              peerId: self.message.peerId,
              chatId: self.message.chatId
            )
          )
        )
      }
    })

    viewController.present(alert, animated: true)
  }

  private func findViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      responder = nextResponder
      if let viewController = responder as? UIViewController {
        return viewController
      }
    }
    return nil
  }
}

// MARK: - Context Menu

extension UIMessageView: UIContextMenuInteractionDelegate, ContextMenuManagerDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    contextMenuManager?.notifyOnContextMenuInteraction(
      interaction,
      configurationForMenuAtLocation: location
    )

    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      guard let self else { return UIMenu(children: []) }

      let copyAction = UIAction(title: "Copy") { _ in
        UIPasteboard.general.string = self.message.text
      }

      var actions: [UIAction] = [copyAction]

      if fullMessage.photoInfo != nil {
        let copyPhotoAction = UIAction(title: "Copy Photo") { [weak self] _ in
          guard let self else { return }
          if let image = newPhotoView.getCurrentImage() {
            UIPasteboard.general.image = image
            ToastManager.shared.showToast(
              "Photo copied to clipboard",
              type: .success,
              systemImage: "doc.on.clipboard"
            )
          }
        }
        actions.append(copyPhotoAction)
      }

      let replyAction = UIAction(title: "Reply") { _ in
        ChatState.shared.setReplyingMessageId(peer: self.message.peerId, id: self.message.id)
      }
      actions.append(replyAction)

      let openLinkAction = UIAction(title: "Open Link") { _ in
        if let url = self.getURLAtLocation(location) {
          self.linkTapHandler?(url)
        }
      }
      if let url = getURLAtLocation(location) {
        actions.append(openLinkAction)
      }

      let deleteAction = UIAction(
        title: "Delete",
        attributes: .destructive
      ) { _ in
        self.showDeleteConfirmation()
      }

      actions.append(deleteAction)
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
    contextMenuManager?.notifyOnContextMenuInteraction(
      interaction,
      willDisplayMenuFor: configuration,
      animator: animator
    )
    Self.contextMenuOpen = true
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willEndFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    contextMenuManager?.notifyOnContextMenuInteraction(
      interaction,
      willEndFor: configuration,
      animator: animator
    )
    Self.contextMenuOpen = false
  }

  func onRequestMenuAuxiliaryPreview(sender: ContextMenuManager) -> UIView? {
    let previewHeight: CGFloat = 45
    let width: CGFloat = 100

    let stackView = UIStackView()
    stackView.axis = .horizontal
    stackView.distribution = .fill
    stackView.spacing = 0
    stackView.alignment = .fill
    stackView.backgroundColor = .clear

    stackView.frame = CGRect(x: 0, y: 0, width: width, height: previewHeight)

    let button = UIButton(type: .custom)
    button.isUserInteractionEnabled = true
    button.setTitle("Will Do", for: .normal)
    button.setTitleColor(.systemBlue, for: .normal)
    button.backgroundColor = .systemGray6
    button.layer.cornerRadius = 22
    button.layer.masksToBounds = true

    button.addTarget(self, action: #selector(handleWillDoTap(_:)), for: .touchUpInside)

    stackView.addArrangedSubview(button)

    return stackView
  }

  @objc private func handleWillDoTap(_ sender: UIButton) {
    Self.contextMenuOpen = false
    interaction?.dismissMenu()

    Task { @MainActor in
      createIssueFunc()
    }
  }

  private func triggerMessageReload() {
    Task { @MainActor in
      await MessagesPublisher.shared
        .messageUpdated(message: fullMessage.message, peer: fullMessage.message.peerId, animated: true)
    }
  }
}

extension NSLayoutConstraint {
  func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
    self.priority = priority
    return self
  }
}

extension Character {
  /// A simple emoji is one scalar and presented to the user as an Emoji
  var isSimpleEmoji: Bool {
    guard let firstScalar = unicodeScalars.first else { return false }
    return firstScalar.properties.isEmoji && firstScalar.value > 0x238c
  }

  /// Checks if the scalars will be merged into an emoji
  var isCombinedIntoEmoji: Bool { unicodeScalars.count > 1 && unicodeScalars.first?.properties.isEmoji ?? false }

  var isEmoji: Bool { isSimpleEmoji || isCombinedIntoEmoji }
}

extension String {
  var containsEmoji: Bool {
    contains { $0.isEmoji }
  }

  var containsOnlyEmojis: Bool {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.allSatisfy { $0.isEmoji }
  }
}

extension Message {
  var hasFile: Bool {
    fileId != nil || photoId != nil
  }

  var hasText: Bool {
    guard let text else { return false }
    return !text.isEmpty
  }

  var hasUnsupportedTypes: Bool {
    videoId != nil || documentId != nil
  }
}

// Add extension for NewPhotoView to access current image
extension NewPhotoView {
  func getCurrentImage() -> UIImage? {
    imageView.imageView.image
  }
}
