import Auth
import Combine
import GRDB
import InlineKit
import Logger
import Nuke
import NukeUI
import SwiftUI
import UIKit

class UIMessageView: UIView {
  // MARK: - Properties

  let fullMessage: FullMessage
  let spaceId: Int64
  private var translationCancellable: AnyCancellable?
  private var isTranslating = false {
    didSet {
      if isTranslating {
        startBlinkingAnimation()
      } else {
        stopBlinkingAnimation()
      }
    }
  }

  var linkTapHandler: ((URL) -> Void)?
  var interaction: UIContextMenuInteraction?

  static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
  var links: [(range: NSRange, url: URL)] = []

  static let attributedCache: NSCache<NSString, NSAttributedString> = {
    let cache = NSCache<NSString, NSAttributedString>()
    cache.countLimit = 1_000
    return cache
  }()

  let metadataView: MessageTimeAndStatus

  var outgoing: Bool {
    fullMessage.message.out == true
  }

  var bubbleColor: UIColor {
    if specificUI {
      UIColor.clear
    } else if outgoing {
      ThemeManager.shared.selected.bubbleBackground
    } else {
      ThemeManager.shared.selected.incomingBubbleBackground
    }
  }

  var textColor: UIColor {
    outgoing ? .white : ThemeManager.shared.selected.primaryTextColor ?? .label
  }

  var message: Message {
    fullMessage.message
  }

  var shouldShowFloatingMetadata: Bool {
    message.hasPhoto && !message.hasText
  }

  var isSticker: Bool {
    fullMessage.message.isSticker == true
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

  var specificUI: Bool {
    isEmojiOnlyMessage || isSticker || shouldShowFloatingMetadata
  }

  var isMultiline: Bool {
    if fullMessage.reactions.count > 0 {
      return true
    }

    if message.hasUnsupportedTypes {
      return false
    }
    if fullMessage.message.documentId != nil {
      return true
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
    return text.count > 24 || text.contains("\n") || text.containsEmoji
  }

  // MARK: - UI Components

  let bubbleView = createBubbleView()
  lazy var containerStack = createContainerStack()
  lazy var singleLineContainer = createSingleLineStack()
  lazy var multiLineContainer = createMultiLineStack()
  lazy var messageLabel = createMessageLabel()
  lazy var unsupportedLabel = createUnsupportedLabel()
  lazy var embedView = createEmbedView()
  lazy var photoView = createPhotoView()
  lazy var newPhotoView = createNewPhotoView()
  lazy var floatingMetadataView = createFloatingMetadataView()
  lazy var documentView = createDocumentView()

  lazy var reactionsFlowView: ReactionsFlowView = {
    let view = ReactionsFlowView(outgoing: outgoing)
    view.onReactionTap = { [weak self] emoji in
      guard let self else { return }

      if let reaction = fullMessage.reactions
        .filter({ $0.emoji == emoji && $0.userId == Auth.shared.getCurrentUserId() ?? 0 }).first
      {
        Transactions.shared.mutate(transaction: .deleteReaction(.init(
          message: message,
          emoji: emoji,
          peerId: message.peerId,
          chatId: message.chatId
        )))
      } else {
        Transactions.shared.mutate(transaction: .addReaction(.init(
          message: message,
          emoji: emoji,
          userId: Auth.shared.getCurrentUserId() ?? 0,
          peerId: message.peerId
        )))
      }
    }
    return view
  }()

  // MARK: - Initialization

  deinit {
    translationCancellable?.cancel()
  }

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

  func handleLinkTap() {
    linkTapHandler = { url in
      UIApplication.shared.open(url)
    }
  }

  func setupViews() {
    bubbleView.isUserInteractionEnabled = true
    messageLabel.isUserInteractionEnabled = true
    containerStack.isUserInteractionEnabled = true

    addSubview(bubbleView)
    bubbleView.addSubview(containerStack)

    setupReplyViewIfNeeded()
    setupFileViewIfNeeded()
    setupPhotoViewIfNeeded()
    setupDocumentViewIfNeeded()
    setupMessageContainer()

    addGestureRecognizer()
    setupDoubleTapGestureRecognizer()
    setupAppearance()
    setupConstraints()
    setupTranslationObserver()
  }

  private func setupTranslationObserver() {
    translationCancellable = TranslatingStatePublisher.shared.publisher.sink { [weak self] translatingSet in
      guard let self else { return }
      let isCurrentlyTranslating = translatingSet.contains { translating in
        translating.messageId == self.message.messageId && translating.peerId == self.message.peerId
      }

      if isCurrentlyTranslating != isTranslating {
        isTranslating = isCurrentlyTranslating
      }
    }
  }

  private func startBlinkingAnimation() {
    UIView.animate(
      withDuration: 0.8,
      delay: 0,
      options: [.autoreverse, .repeat, .allowUserInteraction],
      animations: { [weak self] in
        self?.bubbleView.alpha = 0.6
      }
    )
  }

  private func stopBlinkingAnimation() {
    bubbleView.layer.removeAllAnimations()
    UIView.animate(withDuration: 0.2) { [weak self] in
      self?.bubbleView.alpha = 1
    }
  }

  private func createURLPreviewView(for attachment: FullAttachment) -> URLPreviewView {
    let previewView = URLPreviewView()
    previewView.translatesAutoresizingMaskIntoConstraints = false
    previewView.configure(
      with: attachment.urlPreview!,
      photoInfo: attachment.photoInfo,
      parentViewController: findViewController(),
      outgoing: outgoing
    )
    return previewView
  }

  func addFloatingMetadata() {
    bubbleView.addSubview(floatingMetadataView)

    let padding: CGFloat = 12

    NSLayoutConstraint.activate([
      floatingMetadataView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -padding),
      floatingMetadataView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -padding),
    ])
  }

  func setupReactionsIfNeeded(animatedEmoji: String? = nil) {
    guard !fullMessage.reactions.isEmpty else { return }

    var reactionsDict: [String: (count: Int, userIds: [Int64], latestDate: Date)] = [:]

    for reaction in fullMessage.reactions {
      if let existing = reactionsDict[reaction.emoji] {
        let newCount = existing.count + 1
        let newUserIds = existing.userIds + [reaction.userId]

        let mostRecentDate = max(existing.latestDate, reaction.date)

        reactionsDict[reaction.emoji] = (newCount, newUserIds, mostRecentDate)
      } else {
        reactionsDict[reaction.emoji] = (1, [reaction.userId], reaction.date)
      }
    }

    let sortedReactions = reactionsDict.map {
      (emoji: $0.key, count: $0.value.count, userIds: $0.value.userIds, date: $0.value.latestDate)
    }.sorted { $0.date < $1.date }

    reactionsFlowView.configure(
      with: sortedReactions.map { (emoji: $0.emoji, count: $0.count, userIds: $0.userIds) }
    )
  }

  func setupReplyViewIfNeeded() {
    guard message.repliedToMessageId != nil else { return }

    containerStack.addArrangedSubview(embedView)

    // Add tap gesture to embedView for scroll-to-reply
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleEmbedViewTap))
    embedView.isUserInteractionEnabled = true
    embedView.addGestureRecognizer(tapGesture)

    if let repliedMessage = fullMessage.repliedToMessage {
      let senderName = fullMessage.replyToMessageSender?.firstName ?? "User"
      embedView.configure(
        message: repliedMessage,
        senderName: senderName,
        outgoing: outgoing,
        isOnlyEmoji: isEmojiOnlyMessage
      )
    } else {
      embedView.showNotLoaded(outgoing: outgoing, isOnlyEmoji: isEmojiOnlyMessage)
    }
  }

  @objc func handleEmbedViewTap() {
    guard let repliedId = message.repliedToMessageId else { return }
    NotificationCenter.default.post(
      name: Notification.Name("ScrollToRepliedMessage"),
      object: nil,
      userInfo: ["repliedToMessageId": repliedId, "chatId": message.chatId]
    )
  }

  func setupFileViewIfNeeded() {
    guard fullMessage.file != nil else { return }

    containerStack.addArrangedSubview(photoView)
  }

  func setupPhotoViewIfNeeded() {
    guard fullMessage.photoInfo != nil else { return }

    containerStack.addArrangedSubview(newPhotoView)

    if shouldShowFloatingMetadata {
      addFloatingMetadata()
    }
  }

  func setupDocumentViewIfNeeded() {
    guard fullMessage.documentInfo != nil else { return }

    containerStack.addArrangedSubview(documentView)

    // is this on whole message?
    let documentTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDocumentTap))
    bubbleView.addGestureRecognizer(documentTapGesture)
  }

  @objc func handleDocumentTap() {
    print("HANDLE DOCUMENT TAP")
    NotificationCenter.default.post(
      name: Notification.Name("DocumentTapped"),
      object: nil,
      userInfo: ["fullMessage": fullMessage]
    )
  }

  func setupMessageContainer() {
    if isMultiline {
      setupMultilineMessage()
    } else {
      setupSingleLineMessage()
    }
  }

  func setupMultilineMessage() {
    if message.hasPhoto, message.hasText {
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

      // Insert URLPreviewView(s) for attachments with urlPreview
      for attachment in fullMessage.attachments {
        if let urlPreview = attachment.urlPreview {
          let previewView = createURLPreviewView(for: attachment)
          innerContainer.addArrangedSubview(previewView)
        }
      }

      if fullMessage.reactions.count > 0 {
        print("Setup reactions")
        setupReactionsIfNeeded()
        innerContainer.addArrangedSubview(reactionsFlowView)
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

      // Insert URLPreviewView(s) for attachments with urlPreview
      for attachment in fullMessage.attachments {
        if let urlPreview = attachment.urlPreview {
          let previewView = createURLPreviewView(for: attachment)
          multiLineContainer.addArrangedSubview(previewView)
        }
      }

      if fullMessage.reactions.count > 0 {
        setupReactionsIfNeeded()
        multiLineContainer.addArrangedSubview(reactionsFlowView)
      }

      if message.hasText || isSticker {
        setupMultilineMetadata()
        containerStack.addArrangedSubview(multiLineContainer)
      }
    }
  }

  func setupMultilineMetadata() {
    let metadataContainer = UIStackView()
    metadataContainer.axis = .horizontal
    metadataContainer.addArrangedSubview(UIView()) // Spacer
    metadataContainer.addArrangedSubview(specificUI ? floatingMetadataView : metadataView)
    multiLineContainer.addArrangedSubview(metadataContainer)
  }

  func setupSingleLineMessage() {
    if message.hasUnsupportedTypes {
      singleLineContainer.addArrangedSubview(unsupportedLabel)
    } else {
      singleLineContainer.addArrangedSubview(messageLabel)
    }
    singleLineContainer.addArrangedSubview(metadataView)
    containerStack.addArrangedSubview(singleLineContainer)
  }

  func addGestureRecognizer() {
    messageLabel.isUserInteractionEnabled = true

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    messageLabel.addGestureRecognizer(tapGesture)
  }

  func setupDoubleTapGestureRecognizer() {
    let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
    doubleTapGesture.numberOfTapsRequired = 2

    if let interaction {
      doubleTapGesture.delegate = self
      interaction.view?.gestureRecognizers?.forEach { gesture in
        doubleTapGesture.require(toFail: gesture)
      }
    }

    bubbleView.addGestureRecognizer(doubleTapGesture)
  }

  @objc func handleTap(_ gesture: UITapGestureRecognizer) {
    guard !links.isEmpty else { return }

    // Get tap location in the label's coordinate space
    let tapLocation = gesture.location(in: messageLabel)

    // Create text container to match the label's configuration
    let textContainer = NSTextContainer(size: messageLabel.bounds.size)
    textContainer.lineFragmentPadding = 0
    textContainer.lineBreakMode = messageLabel.lineBreakMode
    textContainer.maximumNumberOfLines = messageLabel.numberOfLines

    // Create layout manager and text storage
    let layoutManager = NSLayoutManager()
    let textStorage = NSTextStorage(attributedString: messageLabel.attributedText ?? NSAttributedString())

    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)

    // Get character index at tap location
    let characterIndex = layoutManager.characterIndex(
      for: tapLocation,
      in: textContainer,
      fractionOfDistanceBetweenInsertionPoints: nil
    )

    // Check if tap is on a link
    for link in links where NSLocationInRange(characterIndex, link.range) {
      print("Link tapped: \(link.url)")
      linkTapHandler?(link.url)
      return
    }
  }

  @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
    // Don't allow reactions on messages that are still sending
    if message.status == .sending {
      return
    }
    let checkmark = "✔️"
    let currentUserId = Auth.shared.getCurrentUserId() ?? 0
    let hasCheckmark = fullMessage.reactions.contains { $0.emoji == checkmark && $0.userId == currentUserId }
    // Heavy haptic
    let generator = UIImpactFeedbackGenerator(style: .heavy)
    generator.prepare()
    generator.impactOccurred()
    if hasCheckmark {
      Transactions.shared.mutate(transaction: .deleteReaction(.init(
        message: message,
        emoji: checkmark,
        peerId: message.peerId,
        chatId: message.chatId
      )))
    } else {
      Transactions.shared.mutate(transaction: .addReaction(.init(
        message: message,
        emoji: checkmark,
        userId: currentUserId,
        peerId: message.peerId
      )))
    }
  }

  enum StackPadding {
    static let top: CGFloat = 8
    static let leading: CGFloat = 12
    static let bottom: CGFloat = 8
    static let trailing: CGFloat = 12
  }

  func setupConstraints() {
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

    let constraints: [NSLayoutConstraint] = switch (
      message.hasPhoto,
      message.hasText
    ) {
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
      bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2).isActive = true
    } else {
      bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
    }
  }

  func setupAppearance() {
    print("👽 fullMessage.displayText  \(fullMessage.displayText )")
    let cacheKey = "\(message.stableId)-\(fullMessage.displayText ?? "")"
    bubbleView.backgroundColor = bubbleColor

    guard let text = fullMessage.displayText else { return }
    if let cachedString = Self.attributedCache.object(forKey: NSString(string: cacheKey)) {
      messageLabel.attributedText = cachedString
      // Re-detect links even with cached string to ensure links array is populated
      if let attributedString = cachedString.mutableCopy() as? NSMutableAttributedString {
        detectAndStyleLinks(in: text, attributedString: attributedString)
      }
      return
    }

    let attributedString = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: UIFont
          .systemFont(ofSize: isSingleEmojiMessage ? 80 : isTripleEmojiMessage ? 70 : isEmojiOnlyMessage ? 32 : 17),
        .foregroundColor: textColor,
      ]
    )

    detectAndStyleLinks(in: text, attributedString: attributedString)

    Self.attributedCache.setObject(attributedString, forKey: cacheKey as NSString)

    messageLabel.attributedText = attributedString
  }

  func detectAndStyleLinks(in text: String, attributedString: NSMutableAttributedString) {
    guard let detector = Self.linkDetector else { return }

    let nsString = text as NSString
    let range = NSRange(location: 0, length: nsString.length)
    let matches = detector.matches(in: text, options: [], range: range)

    links = matches.compactMap { match in
      guard let url = match.url else { return nil }

      let linkAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: outgoing ? UIColor.white.withAlphaComponent(0.9) : ThemeManager.shared.selected
          .primaryTextColor ?? .label,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ]
      attributedString.addAttributes(linkAttributes, range: match.range)

      return (range: match.range, url: url)
    }
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

  func showDeleteConfirmation() {
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

  func findViewController() -> UIViewController? {
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
