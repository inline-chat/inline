
import Auth
import Combine
import GRDB
import InlineKit
import Logger
import Nuke
import NukeUI
import SwiftUI
import TextProcessing
import Translation
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
  var onPhotoTap: ((FullMessage, UIView, UIImage?, URL) -> Void)? {
    didSet {
      bindPhotoTapHandlerIfNeeded()
    }
  }

  var interaction: UIContextMenuInteraction?

  static let attributedCache: NSCache<NSString, NSAttributedString> = {
    let cache = NSCache<NSString, NSAttributedString>()
    cache.countLimit = 1_000
    return cache
  }()

  var outgoing: Bool {
    fullMessage.message.out == true
  }

  var bubbleColor: UIColor {
    if isEmojiOnlyMessage || isSticker || shouldClearBubbleForMedia {
      UIColor.clear
    } else if outgoing {
      // Show red bubble for failed messages using theme-aware color
      if message.status == .failed {
        ThemeManager.shared.selected.failedBubbleBackground
      } else {
        ThemeManager.shared.selected.bubbleBackground
      }
    } else {
      ThemeManager.shared.selected.incomingBubbleBackground
    }
  }

  var textColor: UIColor {
    if outgoing {
      .white
    } else {
      ThemeManager.shared.selected.primaryTextColor ?? .label
    }
  }

  private var forwardHeaderTextColor: UIColor {
    if outgoing, bubbleColor != .clear {
      return .white
    }
    return ThemeManager.shared.selected.accent
  }

  private var forwardHeaderTitle: String {
    if message.forwardFromPeerThreadId != nil {
      let title = fullMessage.forwardFromChatInfo?.title
      return (title?.isEmpty == false) ? title! : "Chat"
    }

    if let peerUserId = message.forwardFromPeerUserId {
      if let peerUserInfo = fullMessage.forwardFromPeerUserInfo {
        return peerUserInfo.user.shortDisplayName
      }

      if peerUserId == message.forwardFromUserId,
         let forwardUserInfo = fullMessage.forwardFromUserInfo
      {
        return forwardUserInfo.user.shortDisplayName
      }
    }

    return "User"
  }

  private var forwardHeaderIsPrivate: Bool {
    if message.forwardFromPeerThreadId != nil {
      return fullMessage.forwardFromChatInfo == nil
    }

    if let peerUserId = message.forwardFromPeerUserId {
      if fullMessage.forwardFromPeerUserInfo != nil {
        return false
      }

      if peerUserId == message.forwardFromUserId,
         fullMessage.forwardFromUserInfo != nil
      {
        return false
      }
      return true
    }

    return true
  }

  private var forwardHeaderText: String {
    if forwardHeaderIsPrivate {
      return "Forwarded from a private chat"
    }
    return "Forwarded from: \(forwardHeaderTitle)"
  }

  var message: Message {
    fullMessage.message
  }

  var shouldShowFloatingMetadata: Bool {
    (message.hasPhoto || message.hasVideo) && !message.hasText && !shouldShowReactionsInsideBubble
  }

  private var shouldClearBubbleForMedia: Bool {
    shouldShowFloatingMetadata && message.forwardFromUserId == nil
  }

  var isSticker: Bool {
    fullMessage.message.isSticker == true
  }

  private var hasMedia: Bool {
    message.hasPhoto || message.hasVideo
  }

  private var isMediaOnlyMessage: Bool {
    hasMedia && !message.hasText
  }

  private var shouldPadForwardHeader: Bool {
    isMediaOnlyMessage && !shouldShowReactionsInsideBubble
  }

  private var shouldShowReactionsOutsideBubble: Bool {
    (hasMedia || isSticker) && !message.hasText && !fullMessage.reactions.isEmpty
  }

  private var shouldShowReactionsInsideBubble: Bool {
    !fullMessage.reactions.isEmpty && !shouldShowReactionsOutsideBubble
  }

  var isEmojiOnlyMessage: Bool {
    if message.repliedToMessageId != nil || message.forwardFromUserId != nil {
      return false
    }
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
    if fullMessage.videoInfo != nil {
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

  private var shouldUseTransparentOutgoingReactions: Bool {
    outgoing && (isEmojiOnlyMessage || isMediaOnlyMessage)
  }

  private var transparentOutgoingReactionOverrides: (primary: UIColor, secondary: UIColor) {
    let baseColor = ThemeManager.shared.selected.reactionIncomingSecoundry ?? .systemGray5
    let primary = darkenedColor(baseColor, amount: 0.08)
    let secondary = darkenedColor(baseColor, amount: 0.04)
    return (primary, secondary)
  }

  private func darkenedColor(_ color: UIColor, amount: CGFloat) -> UIColor {
    UIColor { trait in
      let resolved = color.resolvedColor(with: trait)
      var r: CGFloat = 0
      var g: CGFloat = 0
      var b: CGFloat = 0
      var a: CGFloat = 0
      guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return resolved }
      return UIColor(
        red: max(r - amount, 0),
        green: max(g - amount, 0),
        blue: max(b - amount, 0),
        alpha: a
      )
    }
  }

  // MARK: - UI Components

  let bubbleView = createBubbleView()
  lazy var containerStack = createContainerStack()
  lazy var singleLineContainer = createSingleLineStack()
  lazy var multiLineContainer = createMultiLineStack()
  lazy var messageLabel = createMessageLabel()
  lazy var unsupportedLabel = createUnsupportedLabel()
  lazy var embedView = createEmbedView()
  lazy var forwardHeaderLabel = createForwardHeaderLabel()
  lazy var photoView = createPhotoView()
  lazy var newPhotoView = createNewPhotoView()
  lazy var videoView = createVideoView()
  lazy var floatingMetadataView = createFloatingMetadataView()
  lazy var documentView = createDocumentView()
  lazy var messageAttachmentEmbed = createMessageAttachmentEmbed()
  lazy var metadataView = createMessageTimeAndStatus()
  private weak var metadataContainerView: UIStackView?

  lazy var reactionsFlowView: ReactionsFlowView = {
    let overrides = shouldUseTransparentOutgoingReactions ? transparentOutgoingReactionOverrides : nil
    let view = ReactionsFlowView(
      outgoing: outgoing,
      reactionBackgroundPrimaryOverride: overrides?.primary,
      reactionBackgroundSecondaryOverride: overrides?.secondary
    )
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

    setupForwardHeaderIfNeeded()
    setupReplyViewIfNeeded()
    setupFileViewIfNeeded()
    setupPhotoViewIfNeeded()
    setupVideoViewIfNeeded()
    setupDocumentViewIfNeeded()
    setupMessageContainer()
    setupExternalReactionsIfNeeded()

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

  public func refreshAppearance() {
    setupAppearance()
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

  func highlightMediaOverlay() {
    if fullMessage.photoInfo != nil {
      newPhotoView.showHighlight()
    }
    if fullMessage.videoInfo != nil {
      videoView.showHighlight()
    }
  }

  func clearMediaHighlight() {
    if fullMessage.photoInfo != nil {
      newPhotoView.clearHighlight()
    }
    if fullMessage.videoInfo != nil {
      videoView.clearHighlight()
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

  func addFloatingMetadata(relativeTo mediaView: UIView) {
    bubbleView.addSubview(floatingMetadataView)

    let padding: CGFloat = 12

    NSLayoutConstraint.activate([
      floatingMetadataView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -padding),
      floatingMetadataView.bottomAnchor.constraint(equalTo: mediaView.bottomAnchor, constant: -10),
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

  private func setupExternalReactionsIfNeeded() {
    guard shouldShowReactionsOutsideBubble else { return }
    addSubview(reactionsFlowView)
    setupReactionsIfNeeded()
    reactionsFlowView.setContentHuggingPriority(.required, for: .horizontal)
    reactionsFlowView.setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  private func setupExternalReactionsConstraints() {
    let spacing: CGFloat = 3
    let bottomPadding: CGFloat = spacing + 2
    var constraints: [NSLayoutConstraint] = [
      reactionsFlowView.topAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: spacing),
      reactionsFlowView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomPadding),
      reactionsFlowView.widthAnchor.constraint(lessThanOrEqualTo: bubbleView.widthAnchor),
    ]

    if outgoing {
      constraints.append(reactionsFlowView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor))
      constraints.append(reactionsFlowView.leadingAnchor.constraint(greaterThanOrEqualTo: bubbleView.leadingAnchor))
    } else {
      constraints.append(reactionsFlowView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor))
      constraints.append(reactionsFlowView.trailingAnchor.constraint(lessThanOrEqualTo: bubbleView.trailingAnchor))
    }

    NSLayoutConstraint.activate(constraints)
  }

  func setupReplyViewIfNeeded() {
    guard message.repliedToMessageId != nil else { return }

    containerStack.addArrangedSubview(embedView)

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleEmbedViewTap))
    embedView.isUserInteractionEnabled = true
    embedView.addGestureRecognizer(tapGesture)

    if let embeddedMessage = fullMessage.repliedToMessage {
      embedView.configure(
        embeddedMessage: embeddedMessage,
        kind: .replyInMessage,
        outgoing: outgoing,
        isOnlyEmoji: isEmojiOnlyMessage
      )
    } else {
      embedView.showNotLoaded(kind: .replyInMessage, outgoing: outgoing, isOnlyEmoji: isEmojiOnlyMessage)
    }
  }

  private func setupForwardHeaderIfNeeded() {
    guard message.forwardFromUserId != nil else { return }
    forwardHeaderLabel.textColor = forwardHeaderTextColor
    forwardHeaderLabel.text = forwardHeaderText
    if shouldPadForwardHeader {
      let headerContainer = UIView()
      headerContainer.translatesAutoresizingMaskIntoConstraints = false
      headerContainer.layoutMargins = UIEdgeInsets(
        top: StackPadding.forwardHeaderVertical,
        left: StackPadding.leading,
        bottom: StackPadding.forwardHeaderVertical,
        right: StackPadding.trailing
      )
      headerContainer.insetsLayoutMarginsFromSafeArea = false
      forwardHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
      headerContainer.addSubview(forwardHeaderLabel)
      NSLayoutConstraint.activate([
        forwardHeaderLabel.topAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.topAnchor),
        forwardHeaderLabel.leadingAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.leadingAnchor),
        forwardHeaderLabel.trailingAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.trailingAnchor),
        forwardHeaderLabel.bottomAnchor.constraint(equalTo: headerContainer.layoutMarginsGuide.bottomAnchor),
      ])
      containerStack.addArrangedSubview(headerContainer)
      containerStack.setCustomSpacing(StackPadding.forwardHeaderSpacing, after: headerContainer)
    } else {
      containerStack.addArrangedSubview(forwardHeaderLabel)
      containerStack.setCustomSpacing(StackPadding.forwardHeaderSpacing, after: forwardHeaderLabel)
    }
  }

  @objc  func handleForwardHeaderTap() {
    guard let forwardedMessageId = message.forwardFromMessageId else { return }

    let forwardPeer: Peer? = if let userId = message.forwardFromPeerUserId {
      .user(id: userId)
    } else if let threadId = message.forwardFromPeerThreadId {
      .thread(id: threadId)
    } else {
      nil
    }

    if forwardHeaderIsPrivate,
       let forwardPeer,
       let userId = forwardPeer.asUserId(),
       forwardPeer != message.peerId
    {
      NotificationCenter.default.post(
        name: Notification.Name("NavigateToForwardDestination"),
        object: nil,
        userInfo: ["peerUserId": userId]
      )
      return
    }

    if forwardPeer == nil || forwardPeer == message.peerId {
      NotificationCenter.default.post(
        name: Notification.Name("ScrollToRepliedMessage"),
        object: nil,
        userInfo: ["repliedToMessageId": forwardedMessageId, "chatId": message.chatId]
      )
      return
    }

    if let forwardPeer {
      var userInfo: [AnyHashable: Any] = ["messageId": forwardedMessageId]
      if let userId = forwardPeer.asUserId() {
        userInfo["peerUserId"] = userId
      }
      if let threadId = forwardPeer.asThreadId() {
        userInfo["peerThreadId"] = threadId
      }
      NotificationCenter.default.post(
        name: Notification.Name("NavigateToForwardedMessage"),
        object: nil,
        userInfo: userInfo
      )
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
    bindPhotoTapHandlerIfNeeded()

    if shouldShowFloatingMetadata {
      addFloatingMetadata(relativeTo: newPhotoView)
    }
  }

  private func bindPhotoTapHandlerIfNeeded() {
    guard fullMessage.photoInfo != nil else { return }
    guard let onPhotoTap else {
      newPhotoView.onTap = nil
      return
    }

    newPhotoView.onTap = { [weak self] message, sourceView, sourceImage, url in
      guard let self else { return }
      onPhotoTap(message, sourceView, sourceImage, url)
    }
  }

  func setupVideoViewIfNeeded() {
    guard fullMessage.videoInfo != nil else { return }

    containerStack.addArrangedSubview(videoView)

    if shouldShowFloatingMetadata {
      addFloatingMetadata(relativeTo: videoView)
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
    if hasMedia, message.hasText || shouldShowReactionsInsideBubble {
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

      if message.hasText {
        innerContainer.addArrangedSubview(messageLabel)
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
          innerContainer.addArrangedSubview(messageAttachmentEmbed)
        }
        if attachment.urlPreview != nil {
          let previewView = createURLPreviewView(for: attachment)
          innerContainer.addArrangedSubview(previewView)
        }
      }

      if shouldShowReactionsInsideBubble {
        setupReactionsIfNeeded()
      }

      let metadataContainer = UIStackView()
      metadataContainer.axis = .horizontal
      metadataContainer.translatesAutoresizingMaskIntoConstraints = false
      metadataContainer.addArrangedSubview(UIView())
      metadataContainer.addArrangedSubview(metadataView)
      metadataContainerView = metadataContainer

      if shouldShowReactionsInsideBubble {
        if isEmojiOnlyMessage {
          innerContainer.addArrangedSubview(metadataContainer)
          innerContainer.addArrangedSubview(reactionsFlowView)
        } else {
          innerContainer.addArrangedSubview(reactionsFlowView)
          innerContainer.addArrangedSubview(metadataContainer)
        }
        applyEmojiReactionSpacing(to: innerContainer)
      } else {
        innerContainer.addArrangedSubview(metadataContainer)
      }

      applyReactionMetadataSpacing(to: innerContainer)
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
      if shouldShowReactionsInsideBubble {
        setupReactionsIfNeeded()
      }

      if isEmojiOnlyMessage, shouldShowReactionsInsideBubble {
        if message.hasText || isSticker {
          setupMultilineMetadata()
        }
        multiLineContainer.addArrangedSubview(reactionsFlowView)
        applyEmojiReactionSpacing(to: multiLineContainer)
      } else {
        if shouldShowReactionsInsideBubble {
          multiLineContainer.addArrangedSubview(reactionsFlowView)
          applyEmojiReactionSpacing(to: multiLineContainer)
        }

        if message.hasText || isSticker {
          setupMultilineMetadata()
        }
      }
      applyReactionMetadataSpacing(to: multiLineContainer)
      if !multiLineContainer.arrangedSubviews.isEmpty {
        containerStack.addArrangedSubview(multiLineContainer)
      }
    }
  }

  private func applyEmojiReactionSpacing(to stack: UIStackView) {
    guard isEmojiOnlyMessage, shouldShowReactionsInsideBubble else { return }

    if stack.arrangedSubviews.contains(messageLabel) {
      stack.setCustomSpacing(2, after: messageLabel)
    }

    if let metadataContainerView, stack.arrangedSubviews.contains(metadataContainerView) {
      stack.setCustomSpacing(12, after: metadataContainerView)
    } else if stack.arrangedSubviews.contains(reactionsFlowView) {
      stack.setCustomSpacing(12, after: reactionsFlowView)
    }
  }

  private func applyReactionMetadataSpacing(to stack: UIStackView) {
    guard shouldShowReactionsInsideBubble else { return }
    guard let metadataContainerView else { return }

    let reactionsIndex = stack.arrangedSubviews.firstIndex { $0 === reactionsFlowView }
    let metadataIndex = stack.arrangedSubviews.firstIndex { $0 === metadataContainerView }
    guard let reactionsIndex, let metadataIndex, reactionsIndex != metadataIndex else { return }

    let extraSpacing = isEmojiOnlyMessage
      ? StackPadding.emojiReactionMetadataExtraSpacing
      : StackPadding.reactionMetadataExtraSpacing
    let spacing = stack.spacing + extraSpacing
    if reactionsIndex < metadataIndex {
      stack.setCustomSpacing(spacing, after: reactionsFlowView)
    } else {
      stack.setCustomSpacing(spacing, after: metadataContainerView)
    }
  }

  func setupMultilineMetadata() {
    let metadataContainer = UIStackView()
    metadataContainer.axis = .horizontal
    metadataContainer.addArrangedSubview(UIView()) // Spacer
    if isEmojiOnlyMessage || isSticker || shouldShowFloatingMetadata {
      metadataContainer.addSubview(floatingMetadataView)
      let floatingTopOffset: CGFloat = if isSticker {
        -30
      } else if isEmojiOnlyMessage, shouldShowReactionsInsideBubble {
        -6
      } else {
        -18
      }
      NSLayoutConstraint.activate([
        floatingMetadataView.topAnchor.constraint(
          equalTo: metadataContainer.topAnchor,
          constant: floatingTopOffset
        ),
        floatingMetadataView.trailingAnchor.constraint(equalTo: metadataContainer.trailingAnchor, constant: -4),
      ])
    } else {
      metadataContainer.addArrangedSubview(metadataView)
    }
    metadataContainerView = metadataContainer
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

    // Add tap gesture for mentions and links
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTextViewTap))
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

    let backgroundDoubleTapGesture = UITapGestureRecognizer(
      target: self,
      action: #selector(handleBackgroundDoubleTap)
    )
    backgroundDoubleTapGesture.numberOfTapsRequired = 2

    if let interaction {
      backgroundDoubleTapGesture.delegate = self
      interaction.view?.gestureRecognizers?.forEach { gesture in
        backgroundDoubleTapGesture.require(toFail: gesture)
      }
    }

    addGestureRecognizer(backgroundDoubleTapGesture)
  }

  @objc func handleTextViewTap(_ gesture: UITapGestureRecognizer) {
    let tapLocation = gesture.location(in: messageLabel)
    let textContainer = messageLabel.textContainer
    let layoutManager = messageLabel.layoutManager

    // Get character index at tap location
    let characterIndex = layoutManager.characterIndex(
      for: tapLocation,
      in: textContainer,
      fractionOfDistanceBetweenInsertionPoints: nil
    )

    // Check if tap is on a mention first
    if let attributedText = messageLabel.attributedText {
      var foundMention = false
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
          foundMention = true
          return
        }
      }

      // If not a mention, check for links
      if !foundMention {
        var inlineCodeRange = NSRange(location: 0, length: 0)
        if let isInlineCode = attributedText.attribute(
          .inlineCode,
          at: characterIndex,
          effectiveRange: &inlineCodeRange
        ) as? Bool, isInlineCode {
          let inlineCodeText = (attributedText.string as NSString).substring(with: inlineCodeRange)
          UIPasteboard.general.string = inlineCodeText
          ToastManager.shared.showToast(
            "Copied code",
            type: .success,
            systemImage: "doc.on.doc"
          )
          return
        }

        if let email = attributedText.attribute(.emailAddress, at: characterIndex, effectiveRange: nil) as? String {
          UIPasteboard.general.string = email
          ToastManager.shared.showToast(
            "Copied email",
            type: .success,
            systemImage: "doc.on.doc"
          )
          return
        }

        if let phoneNumber = attributedText
          .attribute(.phoneNumber, at: characterIndex, effectiveRange: nil) as? String
        {
          UIPasteboard.general.string = phoneNumber
          ToastManager.shared.showToast(
            "Copied number",
            type: .success,
            systemImage: "doc.on.doc"
          )
          return
        }

        attributedText.enumerateAttribute(.link, in: NSRange(
          location: 0,
          length: attributedText.length
        )) { value, range, _ in
          if NSLocationInRange(characterIndex, range),
             let url = resolveLinkURL(from: value)
          {
            linkTapHandler?(url)
            return
          }
        }
      }
    }
  }

  private func resolveLinkURL(from value: Any?) -> URL? {
    if let url = value as? URL {
      return url
    }

    guard let urlString = value as? String else {
      return nil
    }

    if let url = URL(string: urlString), url.scheme != nil {
      return url
    }

    return URL(string: "https://\(urlString)")
  }

  @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
    toggleCheckmarkReaction()
  }

  @objc private func handleBackgroundDoubleTap(_ gesture: UITapGestureRecognizer) {
    let location = gesture.location(in: self)
    guard !bubbleView.frame.contains(location) else { return }
    guard bubbleView.frame.minY <= location.y, location.y <= bubbleView.frame.maxY else { return }

    toggleCheckmarkReaction()
  }

  private func toggleCheckmarkReaction() {
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
    static let reactionMetadataExtraSpacing: CGFloat = 4
    static let emojiReactionMetadataExtraSpacing: CGFloat = 8
    static let forwardHeaderVertical: CGFloat = 6
    static let forwardHeaderSpacing: CGFloat = 1
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

    let hasTextOrReactions = message.hasText || shouldShowReactionsInsideBubble

    let constraints: [NSLayoutConstraint] = switch (hasMedia, hasTextOrReactions) {
      case (true, false):
        // Photo only (no text, no reactions)
        withFileConstraints
      case (true, true):
        // Photo with text or reactions
        withFileAndTextConstraints
      default:
        // Text only
        withoutFileConstraints
    }

    NSLayoutConstraint.activate(baseConstraints + constraints)

    if shouldShowReactionsOutsideBubble {
      setupExternalReactionsConstraints()
    } else {
      bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    }

    if outgoing {
      bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2).isActive = true
    } else {
      bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2).isActive = true
    }
  }

  func setupAppearance() {
    let cacheKey = "\(fullMessage.message.entities)\(message.stableId)-\(fullMessage.displayText ?? "")-\(outgoing)"
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
    LinkDetector.shared.applyLinkStyling(
      to: attributedString,
      linkColor: MessageRichTextRenderer.linkColor(for: outgoing)
    )
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
