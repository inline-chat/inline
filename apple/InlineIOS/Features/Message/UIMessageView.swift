import Auth
import Combine
import GRDB
import InlineKit
import Logger
import Nuke
import NukeUI
import SwiftUI
import TextProcessing
import UIKit

class UIMessageView: UIView {
  // MARK: - Properties

  let fullMessage: FullMessage
  let spaceId: Int64
  private var translationCancellable: AnyCancellable?
  private var isTranslating = false {
    didSet {
      if isTranslating {
        startShineAnimation()
      } else {
        stopShineAnimation()
      }
    }
  }

  private var shineEffectView: ShineEffectView?

  var linkTapHandler: ((URL) -> Void)?
  var interaction: UIContextMenuInteraction?

  var links: [(range: NSRange, url: URL)] = []

  static let attributedCache: NSCache<NSString, NSAttributedString> = {
    let cache = NSCache<NSString, NSAttributedString>()
    cache.countLimit = 1_000
    return cache
  }()

  var outgoing: Bool {
    fullMessage.message.out == true
  }

  var bubbleColor: UIColor {
    if isEmojiOnlyMessage || isSticker || shouldShowFloatingMetadata {
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
    message.hasPhoto && !message.hasText && fullMessage.reactions.count == 0
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
    guard let text = fullMessage.displayText else { return false }

    // Check if text contains Chinese characters
    let containsChinese = text.unicodeScalars.contains { scalar in
      (0x4E00 ... 0x9FFF).contains(scalar.value) || // CJK Unified Ideographs
        (0x3400 ... 0x4DBF).contains(scalar.value) || // CJK Unified Ideographs Extension A
        (0x2_0000 ... 0x2_A6DF).contains(scalar.value) // CJK Unified Ideographs Extension B
    }

    // Use lower threshold for Chinese text
    let characterThreshold = containsChinese ? 16 : 24

    return text.count > characterThreshold || text.contains("\n") || text.containsEmoji
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
  lazy var messageAttachmentEmbed = createMessageAttachmentEmbed()
  lazy var metadataView = createMessageTimeAndStatus()

  lazy var reactionsFlowView: ReactionsFlowView = {
    let view = ReactionsFlowView(outgoing: outgoing)
    view.onReactionTap = { [weak self] emoji in
      guard let self else { return }

      if let reaction = fullMessage.reactions
        .filter({ $0.reaction.emoji == emoji && $0.reaction.userId == Auth.shared.getCurrentUserId() ?? 0 }).first
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
    reactionsFlowView.isUserInteractionEnabled = true
    multiLineContainer.isUserInteractionEnabled = true
    singleLineContainer.isUserInteractionEnabled = true

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

  private func startShineAnimation() {
    if shineEffectView == nil {
      let shineView = ShineEffectView(frame: bubbleView.bounds)
      shineView.translatesAutoresizingMaskIntoConstraints = false
      shineView.layer.cornerRadius = bubbleView.layer.cornerRadius
      shineView.layer.masksToBounds = true
      bubbleView.addSubview(shineView)

      NSLayoutConstraint.activate([
        shineView.topAnchor.constraint(equalTo: bubbleView.topAnchor),
        shineView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor),
        shineView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor),
        shineView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor),
      ])

      shineEffectView = shineView
      shineView.startAnimation()
    }
  }

  public func stopShineAnimation() {
    shineEffectView?.stopAnimation()
    shineEffectView?.removeFromSuperview()
    shineEffectView = nil
  }

  func reset() {
    // Cancel translation state observation
    translationCancellable?.cancel()
    translationCancellable = nil

    // Remove shine effect
    stopShineAnimation()

    // Reset appearance-related properties
    bubbleView.backgroundColor = bubbleColor
    messageLabel.textColor = textColor
    
    // Re-setup translation state observation
    setupTranslationObserver()
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
      floatingMetadataView.bottomAnchor.constraint(equalTo: newPhotoView.bottomAnchor, constant: -10),
    ])
  }

  func setupReactionsIfNeeded(animatedEmoji: String? = nil) {
    guard !fullMessage.reactions.isEmpty else { return }

    // Configure reactions using groupedReactions from FullMessage
    reactionsFlowView.configure(
      with: fullMessage.groupedReactions,
      animatedEmoji: animatedEmoji
    )
  }

  func setupReplyViewIfNeeded() {
    guard message.repliedToMessageId != nil else { return }

    containerStack.addArrangedSubview(embedView)

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleEmbedViewTap))
    embedView.isUserInteractionEnabled = true
    embedView.addGestureRecognizer(tapGesture)

    if let embeddedMessage = fullMessage.repliedToMessage {
      let senderName = embeddedMessage.from?.firstName ?? "User"
      embedView.configure(
        embeddedMessage: embeddedMessage,
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
    if message.hasPhoto, message.hasText || fullMessage.reactions.count > 0 {
      let innerContainer = UIStackView()
      innerContainer.axis = .vertical
      innerContainer.isUserInteractionEnabled = true
      innerContainer.translatesAutoresizingMaskIntoConstraints = false
      innerContainer.layoutMargins = UIEdgeInsets(
        top: 0,
        left: StackPadding.leading,
        bottom: 0,
        right: StackPadding.trailing
      )

      innerContainer.spacing = 4
      innerContainer.isLayoutMarginsRelativeArrangement = true
      innerContainer.insetsLayoutMarginsFromSafeArea = false

      innerContainer.addArrangedSubview(messageLabel)

      // Insert URLPreviewView(s) for attachments with urlPreview
      for attachment in fullMessage.attachments {
        if let externalTask = attachment.externalTask, let userInfo = attachment.userInfo {
          messageAttachmentEmbed.configure(
            userInfo: userInfo,
            outgoing: outgoing,
            url: URL(string: externalTask.url ?? ""),
            issueIdentifier: nil,
            title: externalTask.title,
            externalTask: externalTask,
            messageId: message.messageId,
            chatId: message.chatId
          )
          innerContainer.addArrangedSubview(messageAttachmentEmbed)
        }
        if attachment.urlPreview != nil {
          let previewView = createURLPreviewView(for: attachment)
          innerContainer.addArrangedSubview(previewView)
        }
      }

      if fullMessage.reactions.count > 0 {
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
      if message.hasText {
        multiLineContainer.addArrangedSubview(messageLabel)
      }

      // Insert URLPreviewView(s) for attachments with urlPreview
      for attachment in fullMessage.attachments {
        if let externalTask = attachment.externalTask, let userInfo = attachment.userInfo {
          messageAttachmentEmbed.configure(
            userInfo: userInfo,
            outgoing: outgoing,
            url: URL(string: externalTask.url ?? ""),
            issueIdentifier: nil,
            title: externalTask.title,
            externalTask: externalTask,
            messageId: message.messageId,
            chatId: message.chatId
          )
          multiLineContainer.addArrangedSubview(messageAttachmentEmbed)
        }
        if attachment.urlPreview != nil {
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
      }
      containerStack.addArrangedSubview(multiLineContainer)
    }
  }

  func setupMultilineMetadata() {
    let metadataContainer = UIStackView()
    metadataContainer.axis = .horizontal
    metadataContainer.addArrangedSubview(UIView()) // Spacer
    if isEmojiOnlyMessage || isSticker || shouldShowFloatingMetadata {
      metadataContainer.addSubview(floatingMetadataView)
      NSLayoutConstraint.activate([
        floatingMetadataView.topAnchor.constraint(
          equalTo: metadataContainer.topAnchor,
          constant: isSticker ? -30 : -18
        ),
        floatingMetadataView.trailingAnchor.constraint(equalTo: metadataContainer.trailingAnchor, constant: -4),
      ])
    } else {
      metadataContainer.addArrangedSubview(metadataView)
    }
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
    // Get tap location in the label's coordinate space
    let tapLocation = gesture.location(in: messageLabel)

    // Create text container to match the text view's configuration
    let textContainer = NSTextContainer(size: messageLabel.bounds.size)
    textContainer.lineFragmentPadding = messageLabel.textContainer.lineFragmentPadding
    textContainer.lineBreakMode = messageLabel.textContainer.lineBreakMode
    textContainer.maximumNumberOfLines = messageLabel.textContainer.maximumNumberOfLines

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

    // First check if tap is on a mention
    if let attributedText = messageLabel.attributedText {
      attributedText.enumerateAttribute(.mentionUserId, in: NSRange(
        location: 0,
        length: attributedText.length
      )) { value, range, _ in
        if NSLocationInRange(characterIndex, range),
           let userId = value as? Int64
        {
          print("Mention tapped for user ID: \(userId)")
          NotificationCenter.default.post(
            name: Notification.Name("MentionTapped"),
            object: nil,
            userInfo: ["userId": userId]
          )
          return
        }
      }
    }

    // Then check if tap is on a regular link
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
    let hasCheckmark = fullMessage.reactions
      .contains { $0.reaction.emoji == checkmark && $0.reaction.userId == currentUserId }
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

    // Dena: Really hacky, needs refactor.
    if message.hasPhoto, message.hasText, fullMessage.reactions.count > 0 {
      NSLayoutConstraint.activate(baseConstraints + withFileConstraints)
    }
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
    let cacheKey = "\(message.stableId)-\(fullMessage.displayText ?? "")-\(outgoing)"
    bubbleView.backgroundColor = bubbleColor

    guard let text = fullMessage.displayText else { return }

    let entities = fullMessage.translationEntities ?? fullMessage.message.entities

    /// Use cache if available
    if let cachedString = Self.attributedCache.object(forKey: NSString(string: cacheKey)) {
      messageLabel.attributedText = cachedString
      return
    }

    let font = UIFont
      .systemFont(ofSize: isSingleEmojiMessage ? 80 : isTripleEmojiMessage ? 70 : isEmojiOnlyMessage ? 32 : 17)

    /// Apply entities to text and create an NSAttributedString
    let attributedString = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: .init(
        font: font,
        textColor: textColor,
        linkColor: MessageRichTextRenderer.linkColor(for: outgoing),
      )
    )

    detectAndStyleLinks(in: text, attributedString: attributedString)

    Self.attributedCache.setObject(attributedString, forKey: cacheKey as NSString)

    messageLabel.attributedText = attributedString
  }

  func detectAndStyleLinks(in text: String, attributedString: NSMutableAttributedString) {
    // Use centralized LinkDetector for consistent link detection
    let linkMatches = LinkDetector.shared.applyLinkStyling(
      to: attributedString,
      linkColor: MessageRichTextRenderer.linkColor(for: outgoing)
    )

    // Store links for tap handling
    links = linkMatches.map { (range: $0.range, url: $0.url) }
  }

  // func detectAndStyleMentions(in text: String, attributedString: NSMutableAttributedString) {
  //   if let entities = fullMessage.message.entities {
  //     for entity in entities.entities {
  //       let range = NSRange(location: Int(entity.offset), length: Int(entity.length))

  //       // Validate range is within bounds
  //       guard range.location >= 0, range.location + range.length <= text.utf16.count else {
  //         continue
  //       }

  //       switch entity.type {
  //         case .mention:
  //           if case let .mention(mention) = entity.entity {
  //             let mentionColor = MessageRichTextRenderer.mentionColor(for: outgoing)
  //             attributedString.addAttributes([
  //               .foregroundColor: mentionColor,
  //               .mentionUserId: mention.userID,
  //             ], range: range)
  //           }

  //         case .bold:
  //           // Apply bold formatting using existing attributes
  //           let existingAttributes = attributedString.attributes(at: range.location, effectiveRange: nil)
  //           let currentFont = existingAttributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 17)
  //           let boldFont = UIFont.boldSystemFont(ofSize: currentFont.pointSize)
  //           attributedString.addAttribute(.font, value: boldFont, range: range)

  //         default:
  //           break
  //       }
  //     }
  //   }
  // }

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
