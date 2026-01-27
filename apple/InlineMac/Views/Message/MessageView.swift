// MessageView.swift
import AppKit
import Auth
import Combine
import Foundation
import GRDB
import InlineKit
import InlineUI
import Logger
import Nuke
import NukeUI
import SwiftUI
import TextProcessing
import Throttler
import Translation

class MessageViewAppKit: NSView {
  private let feature_relayoutOnBoundsChange = true
  private let log = Log.scoped("MessageView", enableTracing: true)
  static let avatarSize: CGFloat = Theme.messageAvatarSize
  private(set) var fullMessage: FullMessage
  private let dependencies: AppDependencies?
  private var props: MessageViewProps
  private var translationStateCancellable: AnyCancellable?
  private var notionAccessCancellable: AnyCancellable?
  private var from: User {
    fullMessage.from ?? User.deletedInstance
  }

  private var message: Message {
    fullMessage.message
  }

  private var canCopyMessageWithEntities: Bool {
    if Self.isDebugBuild {
      return true
    }
    guard let currentUserId = Auth.shared.currentUserId else { return false }
    return currentUserId == 1_900 || currentUserId == 1_600
  }

  private static var isDebugBuild: Bool {
    #if DEBUG
    return true
    #else
    return false
    #endif
  }

  private var isDM: Bool {
    props.isDM
  }

  private var chatHasAvatar: Bool {
    !isDM
  }

  private var showsAvatar: Bool {
    chatHasAvatar && props.layout.hasAvatar && !outgoing
  }

  private var showsName: Bool {
    chatHasAvatar && props.layout.hasName
  }

  private var hasReactions: Bool {
    props.layout.hasReactions
  }

  private var hasAttachments: Bool {
    props.layout.hasAttachments
  }

  private var outgoing: Bool {
    message.out == true
  }

  private var hasLegacyPhoto: Bool {
    if let file = fullMessage.file, file.fileType == .photo {
      return true
    }
    return false
  }

  private var hasPhoto: Bool {
    props.layout.hasPhoto
  }

  private var hasVideo: Bool {
    props.layout.hasVideo
  }

  private var hasDocument: Bool {
    props.layout.hasDocument
  }

  private var hasReply: Bool {
    props.layout.hasReply
  }

  private var hasForwardHeader: Bool {
    props.layout.hasForwardHeader
  }

  private var hasText: Bool {
    props.layout.hasText
  }

  private var reactionsOutsideBubble: Bool {
    props.layout.reactionsOutsideBubble
  }

  private var shouldUseTransparentOutgoingReactions: Bool {
    outgoing && (emojiMessage || reactionsOutsideBubble)
  }

  private var textWidth: CGFloat {
    props.layout.text?.size.width ?? 1.0
  }

  private var contentWidth: CGFloat {
    props.layout.bubble.size.width
  }

  private var textColor: NSColor {
    Self.textColor(outgoing: outgoing)
  }

  private var forwardHeaderTextColor: NSColor {
    if outgoing, props.layout.hasBubbleColor {
      return .white
    }
    return .controlAccentColor
  }

  private var forwardHeaderTitle: String {
    if message.forwardFromPeerThreadId != nil {
      let title = fullMessage.forwardFromChatInfo?.title
      if let title, !title.isEmpty {
        return title
      }
      return "Chat"
    }

    if message.forwardFromPeerUserId != nil {
      if let forwardUserInfo = fullMessage.forwardFromUserInfo {
        return forwardUserInfo.user.shortDisplayName
      }

      if let peerUserInfo = fullMessage.forwardFromPeerUserInfo {
        return peerUserInfo.user.shortDisplayName
      }
    }

    return "User"
  }

  private var forwardHeaderIsPrivate: Bool {
    if message.forwardFromPeerThreadId != nil {
      return fullMessage.forwardFromChatInfo == nil
    }

    if message.forwardFromPeerUserId != nil {
      if fullMessage.forwardFromUserInfo != nil {
        return false
      }

      if fullMessage.forwardFromPeerUserInfo != nil {
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

  static func textColor(outgoing: Bool) -> NSColor {
    if outgoing {
      NSColor.white
    } else {
      NSColor.labelColor
    }
  }

  static func linkColor(outgoing: Bool) -> NSColor {
    if outgoing {
      NSColor.white
    } else {
      NSColor.linkColor
    }
  }

  private var emojiMessage: Bool {
    props.layout.emojiMessage
  }

  private var bubbleBackgroundColor: NSColor {
    if !props.layout.hasBubbleColor {
      NSColor.clear
    } else if outgoing {
      Theme.messageBubblePrimaryBgColor
    } else {
      Theme.messageBubbleSecondaryBgColor
    }
  }

  private var linkColor: NSColor {
    Self.linkColor(outgoing: outgoing)
  }

  private var mentionColor: NSColor {
    Self.linkColor(outgoing: outgoing)
  }

  private var senderFont: NSFont {
    .systemFont(
      ofSize: 12,
      weight: .semibold
    )
  }

  private var isTimeOverlay: Bool {
    // If we have a document and the message is empty, we don't want to show the time overlay
    if props.layout.hasDocument, !props.layout.hasText {
      false
    } else if emojiMessage {
      true
    } else {
      // for photos, we want to show the time overlay if the message is empty
      !props.layout.hasText
    }
  }

  // State
  private var isMouseInside = false

  // Add gesture recognizer property
  private var longPressGesture: NSPressGestureRecognizer?
  private var doubleClickGesture: NSClickGestureRecognizer?
  private var avatarClickGesture: NSClickGestureRecognizer?

  // MARK: Views

  private lazy var bubbleView: BasicView = {
    let view = BasicView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.cornerRadius = Theme.messageBubbleCornerRadius
    view.backgroundColor = bubbleBackgroundColor
    return view
  }()

  private var shineEffectView: ShineEffectView?

  private lazy var avatarView: UserAvatarView = {
    let view = UserAvatarView(userInfo: fullMessage.senderInfo ?? .deleted)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var nameLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = senderFont
    label.lineBreakMode = .byTruncatingTail

    return label
  }()

  private lazy var forwardHeaderLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .preferredFont(forTextStyle: .callout)
    label.textColor = forwardHeaderTextColor
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.usesSingleLineMode = true
    label.heightAnchor.constraint(equalToConstant: Theme.messageNameLabelHeight).isActive = true
    let clickGesture = NSClickGestureRecognizer(
      target: self,
      action: #selector(handleForwardHeaderClick)
    )
    label.addGestureRecognizer(clickGesture)
    return label
  }()

  private lazy var contentView: NSView = {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var timeAndStateView: MessageTimeAndState = {
    let view = MessageTimeAndState(fullMessage: fullMessage, overlay: isTimeOverlay)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.wantsLayer = true
    return view
  }()

  private lazy var photoView: NewPhotoView = {
    let view = NewPhotoView(fullMessage, scrollState: scrollState)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var videoView: NewVideoView = {
    let view = NewVideoView(fullMessage, scrollState: scrollState)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var documentView: DocumentView? = {
    guard let documentInfo = fullMessage.documentInfo else { return nil }

    let view = DocumentView(
      documentInfo: documentInfo,
      fullMessage: self.fullMessage,
      white: outgoing
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// Attachments
  ///
  /// Will do tasks, Loom embeds, etc.
  private var attachmentsView: MessageAttachmentsView?

  private func createAttachmentsView() -> MessageAttachmentsView? {
    let view = MessageAttachmentsView(attachments: fullMessage.attachments, message: message)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  /// Reply
  private lazy var replyView: EmbeddedMessageView = {
    let view = EmbeddedMessageView(style: outgoing ? .white : .colored)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.setRelatedMessage(fullMessage.message)
    if let embeddedMessage = fullMessage.repliedToMessage {
      view.update(with: embeddedMessage, kind: .replyInMessage)
    }
    return view
  }()

  private var useTextKit2: Bool = true

  private var prevDelegate: NSTextViewportLayoutControllerDelegate?

  private lazy var textView: NSTextView = {
    if useTextKit2 {
      let textView = MessageTextView(usingTextLayoutManager: true)
      textView.translatesAutoresizingMaskIntoConstraints = false
      textView.isEditable = false
      textView.isSelectable = true
      textView.backgroundColor = .clear
      textView.drawsBackground = false
      // Clips to bounds = false fucks up performance so badly. what!?
      // textView.clipsToBounds = true
      textView.textContainerInset = MessageTextConfiguration.containerInset
      // FIXME: Extract font to a variable
      textView.font = .systemFont(ofSize: props.layout.fontSize)
      textView.textColor = textColor
      textView.wantsLayer = true
      textView.layerContentsRedrawPolicy = .onSetNeedsDisplay
      textView.layer?.drawsAsynchronously = true
      textView.layer?.needsDisplayOnBoundsChange = true

      let textContainer = textView.textContainer
      textContainer?.widthTracksTextView = false
      textContainer?.heightTracksTextView = false

      // Configure basic text view behavior
      textView.allowsImageEditing = false
      textView.isGrammarCheckingEnabled = false
      textView.isContinuousSpellCheckingEnabled = false
      textView.isAutomaticQuoteSubstitutionEnabled = false
      textView.isAutomaticDashSubstitutionEnabled = false
      textView.isAutomaticTextReplacementEnabled = false

      textView.isVerticallyResizable = false
      textView.isHorizontallyResizable = false
      textView.delegate = self

      // we need default delegate to handle rendering (GENIUS)
      prevDelegate = textView.textLayoutManager?.textViewportLayoutController.delegate
      textView.textLayoutManager?.textViewportLayoutController.delegate = self

      // In NSTextView you need to customize link colors here otherwise the attributed string for links
      // does not have any effect.
      textView.linkTextAttributes = [
        .foregroundColor: linkColor,
        // .underlineStyle: NSUnderlineStyle.single.rawValue,
        .cursor: NSCursor.pointingHand,
      ]

      // Match the sizes and spacing with the size calculator we use to calculate cell height
      MessageTextConfiguration.configureTextContainer(textContainer!)
      MessageTextConfiguration.configureTextView(textView)

      return textView
    } else {
      let textContainer = NSTextContainer(size: props.layout.text?.size ?? .zero)
      let layoutManager = NSLayoutManager()
      let textStorage = NSTextStorage()

      textStorage.addLayoutManager(layoutManager)
      layoutManager.addTextContainer(textContainer)

      let textView = MessageTextView(frame: .zero, textContainer: textContainer)

      // Essential TextKit 1 optimizations
      textContainer.lineFragmentPadding = 0
      textContainer.maximumNumberOfLines = 0
      textContainer.widthTracksTextView = false
      textContainer.heightTracksTextView = false
      textContainer.lineBreakMode = .byClipping
      textContainer.maximumNumberOfLines = 0
      textContainer.containerSize = props.layout.text?.size ?? .zero
      textContainer.size = props.layout.text?.size ?? .zero

      //    layoutManager.showsControlCharacters = true
      //    layoutManager.showsInvisibleCharacters = true

      layoutManager.usesDefaultHyphenation = false
      layoutManager.allowsNonContiguousLayout = true
      layoutManager.backgroundLayoutEnabled = true

      // Match your existing configuration
      textView.isEditable = false
      textView.isSelectable = true
      textView.usesFontPanel = false
      textView.textContainerInset = MessageTextConfiguration.containerInset
      textView.linkTextAttributes = [
        .foregroundColor: linkColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
        .cursor: NSCursor.pointingHand,
      ]
      textView.delegate = self
      textView.wantsLayer = true
      textView.layer?.drawsAsynchronously = true
      textView.layerContentsRedrawPolicy = .onSetNeedsDisplay
      textView.layer?.contentsGravity = .topLeft
      textView.layer?.needsDisplayOnBoundsChange = true
      textView.drawsBackground = false
      textView.isVerticallyResizable = false
      textView.isHorizontallyResizable = false
      textView.translatesAutoresizingMaskIntoConstraints = false
      return textView
    }
  }()

  private var reactionsView: MessageReactionsView?
  private var entityClickGesture: NSClickGestureRecognizer?

  // MARK: - Link Detection

  /// Stores detected links for tap handling
  private var detectedLinks: [(range: NSRange, url: URL)] = []

  /// Handles link clicks by opening the URL in the default browser
  private func handleLinkClick(at characterIndex: Int) {
    for link in detectedLinks where NSLocationInRange(characterIndex, link.range) {
      log.debug("Link clicked: \(link.url)")
      NSWorkspace.shared.open(link.url)
      return
    }
  }

  private func linkURLForContextMenu(at characterIndex: Int) -> URL? {
    guard characterIndex != NSNotFound else { return nil }

    if let match = detectedLinks.first(where: { NSLocationInRange(characterIndex, $0.range) }) {
      return match.url
    }

    guard let textStorage = textView.textStorage, characterIndex < textStorage.length else { return nil }

    if let value = textStorage.attribute(.link, at: characterIndex, effectiveRange: nil) {
      if let url = value as? URL {
        return url
      }
      if let urlString = value as? String, let url = URL(string: urlString) {
        return url
      }
    }

    return nil
  }

  // MARK: - Initialization

  init(
    fullMessage: FullMessage,
    props: MessageViewProps,
    dependencies: AppDependencies? = nil,
    isScrolling: Bool = false
  ) {
    self.fullMessage = fullMessage
    self.props = props
    self.dependencies = dependencies
    scrollState = isScrolling ? .scrolling : .idle
    super.init(frame: .zero)
    setupView()
    setupNotionAccessObserver()

    DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
      self?.setupScrollStateObserver()
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle

  override func layout() {
    super.layout()
  }

  // MARK: - Setup

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let observer = notificationObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    translationStateCancellable?.cancel()
  }

  private func setupView() {
    // For performance of animations
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.drawsAsynchronously = true

    addSubview(bubbleView)

    if showsAvatar {
      addSubview(avatarView)
    }

    if showsName {
      addSubview(nameLabel)
      let name = from.firstName ?? from.username ?? ""
      let nameForInitials = UserAvatar.getNameForInitials(user: from)
      nameLabel.stringValue = outgoing ? "You" : name
      nameLabel.textColor = NSColor(
        InitialsCircle.ColorPalette
          .color(for: nameForInitials)
      )
    }

    addSubview(contentView)

    if hasForwardHeader {
      forwardHeaderLabel.textColor = forwardHeaderTextColor
      forwardHeaderLabel.stringValue = forwardHeaderText
      contentView.addSubview(forwardHeaderLabel)
    }

    if hasReply {
      contentView.addSubview(replyView)
    }

    if hasPhoto {
      contentView.addSubview(photoView)
    }

    if hasVideo {
      contentView.addSubview(videoView)
    }

    if hasDocument, let documentView {
      contentView.addSubview(documentView)
    }

    if hasText {
      contentView.addSubview(textView)
      setupEntityClickHandling()
    }

    if hasReactions {
      setupReactions(animate: false)
    }

    if hasAttachments {
      attachmentsView = createAttachmentsView()
      contentView.addSubview(attachmentsView!)
    }

    addSubview(timeAndStateView)

    setupMessageText()
    setupContextMenu()
    setupGestureRecognizers()

    // Setup translation state observation
    setupTranslationStateObservation()
  }

  private func setupTranslationStateObservation() {
    translationStateCancellable = TranslatingStatePublisher.shared.publisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] translatingSet in
        guard let self else { return }
        let isTranslating = translatingSet.contains(
          TranslatingStatePublisher.TranslatingStateHolder.Translating(
            messageId: message.messageId,
            peerId: message.peerId
          )
        )
        updateShineEffect(isTranslating: isTranslating)
      }
  }

  private func setupEntityClickHandling() {
    let gesture = NSClickGestureRecognizer(target: self, action: #selector(handleEntityClick(_:)))
    gesture.numberOfClicksRequired = 1
    gesture.delaysPrimaryMouseButtonEvents = false
    gesture.delegate = self
    textView.addGestureRecognizer(gesture)
    entityClickGesture = gesture
  }

  @objc private func handleEntityClick(_ gesture: NSClickGestureRecognizer) {
    guard gesture.state == .ended else { return }
    guard let layoutManager = textView.layoutManager,
          let textContainer = textView.textContainer
    else { return }

    let location = gesture.location(in: textView)
    let characterIndex = layoutManager.characterIndex(
      for: location,
      in: textContainer,
      fractionOfDistanceBetweenInsertionPoints: nil
    )

    guard characterIndex != NSNotFound,
          let textStorage = textView.textStorage,
          characterIndex < textStorage.length
    else { return }

    if let messageTextView = textView as? MessageTextView,
       let codeRange = messageTextView.codeBlockRange(at: location)
    {
      let codeText = (textStorage.string as NSString).substring(with: codeRange)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(codeText, forType: .string)
      ToastCenter.shared.showSuccess("Copied code")
      performProgressiveHaptic()
      return
    }

    var inlineCodeRange = NSRange(location: 0, length: 0)
    if let isInlineCode = textStorage.attribute(
      .inlineCode,
      at: characterIndex,
      effectiveRange: &inlineCodeRange
    ) as? Bool, isInlineCode {
      let inlineCodeText = (textStorage.string as NSString).substring(with: inlineCodeRange)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(inlineCodeText, forType: .string)
      ToastCenter.shared.showSuccess("Copied code")
      performProgressiveHaptic()
      return
    }

    if let email = textStorage.attribute(.emailAddress, at: characterIndex, effectiveRange: nil) as? String {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(email, forType: .string)
      ToastCenter.shared.showSuccess("Copied email")
      performProgressiveHaptic()
    } else if let phoneNumber = textStorage
      .attribute(.phoneNumber, at: characterIndex, effectiveRange: nil) as? String
    {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(phoneNumber, forType: .string)
      ToastCenter.shared.showSuccess("Copied number")
      performProgressiveHaptic()
    }
  }

  private func performProgressiveHaptic() {
    let performer = NSHapticFeedbackManager.defaultPerformer
    performer.perform(.generic, performanceTime: .default)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
      performer.perform(.levelChange, performanceTime: .default)
    }
  }

  private func updateShineEffect(isTranslating: Bool) {
    if isTranslating {
      if shineEffectView == nil {
        let shineView = ShineEffectView(frame: bubbleView.bounds)
        shineView.translatesAutoresizingMaskIntoConstraints = false
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
    } else {
      shineEffectView?.stopAnimation()
      shineEffectView?.removeFromSuperview()
      shineEffectView = nil
    }
  }

  // MARK: - Reactions UI

  private func clearReactionsConstraints() {
    let constraintsToDeactivate = [
      reactionViewWidthConstraint,
      reactionViewHeightConstraint,
      reactionViewTopConstraint,
      reactionViewLeadingConstraint,
      reactionViewTrailingConstraint,
    ].compactMap(\.self)
    NSLayoutConstraint.deactivate(constraintsToDeactivate)

    reactionViewWidthConstraint = nil
    reactionViewHeightConstraint = nil
    reactionViewTopConstraint = nil
    reactionViewLeadingConstraint = nil
    reactionViewTrailingConstraint = nil
  }

  private func setupReactions(animate: Bool) {
    if let oldView = reactionsView {
      oldView.removeFromSuperview()
    }
    clearReactionsConstraints()

    // View
    let view = MessageReactionsView()
    view.update(
      fullMessage: fullMessage,
      groups: fullMessage.groupedReactions,
      layoutItems: props.layout.reactionItems,
      forceIncomingStyle: reactionsOutsideBubble,
      transparentOutgoingStyle: shouldUseTransparentOutgoingReactions,
      animate: animate
    )
    view.translatesAutoresizingMaskIntoConstraints = false
    reactionsView = view

    // debug
//    let view = NSView()
//    view.translatesAutoresizingMaskIntoConstraints = false
//    view.wantsLayer = true
//    view.layer?.backgroundColor = NSColor.red.cgColor
//    reactionsView = view

    if hasText, textView.superview != nil {
      if reactionsOutsideBubble {
        addSubview(reactionsView!)
      } else {
        contentView.addSubview(reactionsView!, positioned: .below, relativeTo: textView)
      }
    } else {
      if reactionsOutsideBubble {
        addSubview(reactionsView!)
      } else {
        contentView.addSubview(reactionsView!)
      }
    }

    // Reactions
    if let reactionsPlan = props.layout.reactions, let reactionsView {
      reactionViewHeightConstraint = reactionsView.heightAnchor.constraint(
        equalToConstant: reactionsPlan.size.height
      )
      reactionViewWidthConstraint = reactionsView.widthAnchor.constraint(
        equalToConstant: reactionsPlan.size.width
      )
      if reactionsOutsideBubble {
        reactionViewTopConstraint = reactionsView.topAnchor.constraint(
          equalTo: bubbleView.bottomAnchor,
          constant: props.layout.reactionsOutsideBubbleTopInset
        )
        if outgoing {
          reactionViewTrailingConstraint = reactionsView.trailingAnchor.constraint(
            equalTo: bubbleView.trailingAnchor,
            constant: -reactionsPlan.spacing.right
          )
        } else {
          reactionViewLeadingConstraint = reactionsView.leadingAnchor.constraint(
            equalTo: bubbleView.leadingAnchor,
            constant: reactionsPlan.spacing.left
          )
        }
      } else {
        reactionViewTopConstraint = reactionsView.topAnchor.constraint(
          equalTo: contentView.topAnchor,
          constant: props.layout.reactionsViewTop
        )
        reactionViewLeadingConstraint = reactionsView.leadingAnchor.constraint(
          equalTo: contentView.leadingAnchor,
          constant: reactionsPlan.spacing.left
        )
      }

      NSLayoutConstraint.activate(
        [
          reactionViewHeightConstraint,
          reactionViewWidthConstraint,
          reactionViewTopConstraint,
          reactionViewLeadingConstraint,
          reactionViewTrailingConstraint,
        ].compactMap(\.self)
      )
    }
  }

  private func updateReactionsSizes() {
    reactionsView?.update(
      fullMessage: fullMessage,
      groups: fullMessage.groupedReactions,
      layoutItems: props.layout.reactionItems,
      forceIncomingStyle: reactionsOutsideBubble,
      transparentOutgoingStyle: shouldUseTransparentOutgoingReactions,
      animate: false
    )
  }

  private func updateReactions(prev _: FullMessage, next: FullMessage, props: MessageViewProps) {
    if reactionsView != nil, next.reactions.count == 0 {
      log.trace("Removing reactions view")
      // Remove
      reactionsView?.removeFromSuperview()
      reactionsView = nil
      clearReactionsConstraints()
      return
    }

    let shouldPlaceOutside = props.layout.reactionsOutsideBubble
    if let reactionsView, shouldPlaceOutside != (reactionsView.superview === self) {
      log.trace("Rebuilding reactions view for placement change")
      setupReactions(animate: false)
      needsUpdateConstraints = true
      layoutSubtreeIfNeeded()
      return
    }

    if reactionsView == nil, next.reactions.count > 0 {
      log.trace("Adding reactions view \(props.layout.reactions)")
      // Added
      setupReactions(animate: true)
      needsUpdateConstraints = true
      layoutSubtreeIfNeeded()
    } else {
      log.trace("Updating reactions view")
      reactionsView?.update(
        fullMessage: next,
        groups: next.groupedReactions,
        layoutItems: props.layout.reactionItems,
        forceIncomingStyle: reactionsOutsideBubble,
        transparentOutgoingStyle: shouldUseTransparentOutgoingReactions,
        animate: true
      )
    }
  }

  private func setupGestureRecognizers() {
    // Add long press gesture recognizer
    longPressGesture = NSPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
    longPressGesture?.minimumPressDuration = 0.5
    longPressGesture?.allowableMovement = 10
    longPressGesture?.delegate = self
    if let gesture = longPressGesture {
      addGestureRecognizer(gesture)
    }

    // Add double click gesture recognizer
    doubleClickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
    doubleClickGesture?.numberOfClicksRequired = 2
    doubleClickGesture?.delaysPrimaryMouseButtonEvents = false
    doubleClickGesture?.delegate = self
    if let gesture = doubleClickGesture {
      addGestureRecognizer(gesture)
    }

    if showsAvatar {
      avatarClickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleAvatarClick(_:)))
      if let gesture = avatarClickGesture {
        avatarView.addGestureRecognizer(gesture)
      }
    }
  }

  @objc private func handleLongPress(_ gesture: NSPressGestureRecognizer) {
    if gesture.state == .began {
      // Provide haptic feedback
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)

      // Show reaction overlay
      showReactionOverlay()
    }
  }

  @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
    // Check if click is within text view bounds
    let location = gesture.location(in: self)
    if hasText, let textViewFrame = textView.superview?.convert(textView.frame, to: self),
       textViewFrame.contains(location)
    {
      return // Ignore double click if it's on the text
    }

    // Provide haptic feedback
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)

    guard let currentUserId = Auth.shared.currentUserId else { return }
    let weReacted = fullMessage.groupedReactions.contains { reaction in
      reaction.reactions.contains { fullReaction in
        fullReaction.reaction.userId == currentUserId
      }
    }

    let emoji = "✔️"

    // Set reaction
    if weReacted {
      // Remove reaction
      Task(priority: .userInitiated) {
        try await Api.realtime.send(.deleteReaction(
          emoji: emoji,
          message: fullMessage.message,
        ))
      }
    } else {
      // Add reaction
      Task(priority: .userInitiated) {
        try await Api.realtime.send(.addReaction(
          emoji: emoji,
          message: fullMessage.message,
        ))
      }
    }
  }

  @objc private func handleAvatarClick(_: NSClickGestureRecognizer) {
    guard !isDM else { return }
    guard let user = fullMessage.senderInfo?.user else { return }

    Task { @MainActor in
      // TODO: Fix this so if user clicks on a message from a user they don't have a chat with, it creates a chat
      // let _ = try await DataManager.shared.createPrivateChat(userId: user.id)
      Nav.main.open(.chat(peer: .user(id: user.id)))
    }
  }

  @objc private func handleForwardHeaderClick(_: NSClickGestureRecognizer) {
    guard let forwardedMessageId = message.forwardFromMessageId else { return }

    var forwardPeer: Peer?
    if let peerUserId = message.forwardFromPeerUserId {
      let currentUserId = Auth.shared.currentUserId
      if let senderId = message.forwardFromUserId, senderId != currentUserId {
        forwardPeer = .user(id: senderId)
      } else {
        forwardPeer = .user(id: peerUserId)
      }
    } else if let threadId = message.forwardFromPeerThreadId {
      forwardPeer = .thread(id: threadId)
    }

    let targetPeer = forwardPeer ?? message.peerId

    if forwardHeaderIsPrivate, targetPeer.isPrivate, targetPeer != message.peerId {
      openChat(peer: targetPeer)
      return
    }

    if targetPeer == message.peerId {
      let chatState = ChatsManager.shared.get(for: targetPeer, chatId: message.chatId)
      chatState.scrollTo(msgId: forwardedMessageId)
      return
    }

    guard let chat = try? Chat.getByPeerId(peerId: targetPeer) else {
      ToastCenter.shared.showError("You don't have access to that chat")
      return
    }

    openChat(peer: targetPeer)
    let chatState = ChatsManager.shared.get(for: targetPeer, chatId: chat.id)
    chatState.scrollTo(msgId: forwardedMessageId)
  }

  private func setupConstraints() {
    var constraints: [NSLayoutConstraint] = []
    let layout = props.layout

    defer {
      NSLayoutConstraint.activate(constraints)
    }

    // Note:
    // There shouldn't be any calculations of sizes or spacing here. All of it must be off-loaded to SizeCalculator
    // and stored in the layout plan.

    // Content View Top and Bottom Insets
//    contentView.edgeInsets = NSEdgeInsets(
//      top: layout.topMostContentTopSpacing,
//      left: 0,
//      bottom: layout.bottomMostContentBottomSpacing,
//      right: 0
//    )

    if let avatar = layout.avatar, showsAvatar {
      constraints.append(
        contentsOf: [
          avatarView.leadingAnchor
            .constraint(equalTo: leadingAnchor, constant: avatar.spacing.left),
          avatarView.topAnchor
            .constraint(
              equalTo: topAnchor,
              constant: avatar.spacing.top + layout.wrapper.spacing.top
            ),
          avatarView.widthAnchor.constraint(equalToConstant: avatar.size.width),
          avatarView.heightAnchor.constraint(equalToConstant: avatar.size.height),
        ]
      )
    }

    if let name = layout.name, showsName {
      constraints.append(
        contentsOf: [
          nameLabel.leadingAnchor
            .constraint(
              equalTo: leadingAnchor,
              constant: layout.nameAndBubbleLeading + name.spacing.left
            ),
          nameLabel.topAnchor
            .constraint(equalTo: topAnchor, constant: layout.wrapper.spacing.top),
          nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
          nameLabel.heightAnchor
            .constraint(equalToConstant: name.size.height),
        ]
      )
    }

    // Bubble And Content View

    if layout.hasName {
      // if we have name, attach bubble to it
      constraints.append(contentsOf: [
        bubbleView.topAnchor.constraint(
          equalTo: nameLabel.bottomAnchor
        ),
        contentView.topAnchor.constraint(
          equalTo: nameLabel.bottomAnchor
        ),
      ])

    } else {
      // otherwise attach to top
      constraints.append(contentsOf: [
        bubbleView.topAnchor.constraint(
          equalTo: topAnchor,
          constant: layout.wrapper.spacing.top
        ),
        contentView.topAnchor.constraint(
          equalTo: topAnchor,
          constant: layout.wrapper.spacing.top
        ),
      ])
    }

    bubbleViewHeightConstraint = bubbleView.heightAnchor.constraint(equalToConstant: layout.bubble.size.height)
    bubbleViewWidthConstraint = bubbleView.widthAnchor.constraint(
      equalToConstant: layout.bubble.size.width
    )
    contentViewWidthConstraint = contentView.widthAnchor.constraint(equalToConstant: layout.bubble.size.width)
    contentViewHeightConstraint = contentView.heightAnchor.constraint(equalToConstant: layout.bubble.size.height)

    let sidePadding = Theme.messageSidePadding
    let contentLeading = chatHasAvatar ? layout.nameAndBubbleLeading : sidePadding

    // Depending on outgoing or incoming message
    let contentViewSideAnchor =
      !outgoing ?
      contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeading) :
      contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sidePadding)
    let bubbleViewSideAnchor =
      !outgoing ?
      bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentLeading) :
      bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -sidePadding)

    constraints.append(
      contentsOf: [
        bubbleViewHeightConstraint,
        bubbleViewWidthConstraint,
        bubbleViewSideAnchor,

        contentViewHeightConstraint,
        contentViewWidthConstraint,
        contentViewSideAnchor,
      ]
    )

    // Text

    if let text = layout.text {
      textViewWidthConstraint = textView.widthAnchor
        .constraint(equalToConstant: text.size.width)
      textViewHeightConstraint = textView.heightAnchor
        .constraint(equalToConstant: text.size.height)
      textViewTopConstraint = textView.topAnchor.constraint(
        equalTo: contentView.topAnchor,
        constant: layout.textContentViewTop
      )
      textViewLeadingConstraint = textView.leadingAnchor.constraint(
        equalTo: contentView.leadingAnchor,
        constant: text.spacing.left
      )

      constraints.append(
        contentsOf: [
          textViewHeightConstraint!,
          textViewWidthConstraint!,
          textViewTopConstraint!,
          textViewLeadingConstraint!,
        ]
      )

      // TODO: Handle RTL
    }

    // Reactions
    if let reactionsPlan = layout.reactions, let reactionsView {
      reactionViewHeightConstraint = reactionsView.heightAnchor.constraint(
        equalToConstant: reactionsPlan.size.height
      )
      reactionViewWidthConstraint = reactionsView.widthAnchor.constraint(
        equalToConstant: reactionsPlan.size.width
      )
      if layout.reactionsOutsideBubble {
        reactionViewTopConstraint = reactionsView.topAnchor.constraint(
          equalTo: bubbleView.bottomAnchor,
          constant: layout.reactionsOutsideBubbleTopInset
        )
        if outgoing {
          reactionViewTrailingConstraint = reactionsView.trailingAnchor.constraint(
            equalTo: bubbleView.trailingAnchor,
            constant: -reactionsPlan.spacing.right
          )
        } else {
          reactionViewLeadingConstraint = reactionsView.leadingAnchor.constraint(
            equalTo: bubbleView.leadingAnchor,
            constant: reactionsPlan.spacing.left
          )
        }
      } else {
        reactionViewTopConstraint = reactionsView.topAnchor.constraint(
          equalTo: contentView.topAnchor,
          constant: layout.reactionsViewTop
        )
        reactionViewLeadingConstraint = reactionsView.leadingAnchor.constraint(
          equalTo: contentView.leadingAnchor,
          constant: reactionsPlan.spacing.left
        )
      }

      constraints.append(
        contentsOf: [
          reactionViewHeightConstraint,
          reactionViewWidthConstraint,
          reactionViewTopConstraint,
          reactionViewLeadingConstraint,
          reactionViewTrailingConstraint,
        ].compactMap(\.self)
      )
    }

    // Time
    if let time = layout.time {
      let timeWidthConstraint = timeAndStateView.widthAnchor.constraint(
        equalToConstant: time.size.width
      )
      let timeHeightConstraint = timeAndStateView.heightAnchor.constraint(
        equalToConstant: time.size.height
      )
      let timeTrailingConstraint = timeAndStateView.trailingAnchor
        .constraint(
          equalTo: bubbleView.trailingAnchor,
          constant: -time.spacing.right
        )

      constraints.append(contentsOf: [
        timeWidthConstraint,
        timeHeightConstraint,
        timeTrailingConstraint,
      ])

      if layout.placesTimeAboveReactions {
        timeViewTopConstraint = timeAndStateView.topAnchor.constraint(
          equalTo: contentView.topAnchor,
          constant: layout.timeViewTop
        )
        constraints.append(timeViewTopConstraint!)
      } else {
        timeViewBottomConstraint = timeAndStateView.bottomAnchor.constraint(
          equalTo: bubbleView.bottomAnchor,
          constant: -time.spacing.bottom
        )
        constraints.append(timeViewBottomConstraint!)
      }
    }

    if let forwardHeader = layout.forwardHeader {
      forwardHeaderTopConstraint = forwardHeaderLabel.topAnchor.constraint(
        equalTo: contentView.topAnchor,
        constant: forwardHeader.spacing.top
      )

      constraints.append(
        contentsOf: [
          forwardHeaderLabel.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: forwardHeader.spacing.left
          ),
          forwardHeaderLabel.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor,
            constant: -forwardHeader.spacing.right
          ),
          forwardHeaderTopConstraint!,
        ]
      )
    }

    if let reply = layout.reply {
      replyViewTopConstraint = replyView.topAnchor.constraint(
        equalTo: contentView.topAnchor,
        constant: layout.replyContentTop
      )

      constraints.append(
        contentsOf: [
          replyView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: reply.spacing.left),
          replyView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -reply.spacing.right),
          replyViewTopConstraint!,
        ]
      )
    }

    // Document
    if let document = layout.document, let documentView {
      documentViewTopConstraint = documentView.topAnchor.constraint(
        equalTo: contentView.topAnchor,
        constant: layout.documentContentViewTop
      )

      constraints.append(
        contentsOf: [
          documentViewTopConstraint!,
          documentView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: document.spacing.left),
          documentView.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor,
            constant: -document.spacing.right
          ),
        ]
      )
    }

    // // Attachments
    // if let attachments = layout.attachments, let attachmentsView {
    //   attachmentsViewTopConstraint = attachmentsView.topAnchor.constraint(
    //     equalTo: contentView.topAnchor,
    //     constant: layout.attachmentsContentViewTop
    //   )

    //   constraints.append(contentsOf: [
    //     attachmentsViewTopConstraint!,
    //     attachmentsView.leadingAnchor.constraint(
    //       equalTo: contentView.leadingAnchor,
    //       constant: 0
    //     ),
    //     attachmentsView.trailingAnchor.constraint(
    //       equalTo: contentView.trailingAnchor,
    //       constant: 0
    //     ),
    //   ])
    // }

    // Photo

    if let photo = layout.photo {
      photoViewTopConstraint = photoView.topAnchor.constraint(
        equalTo: contentView.topAnchor,
        constant: layout.photoContentViewTop
      )
      photoViewHeightConstraint = photoView.heightAnchor.constraint(equalToConstant: photo.size.height)
      photoViewWidthConstraint = photoView.widthAnchor
        .constraint(equalToConstant: photo.size.width)
      constraints.append(contentsOf: [
        photoViewTopConstraint!,
        photoViewHeightConstraint!,
        photoViewWidthConstraint!,
        photoView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: photo.spacing.left),
      ])
    }

    // Video

    if let video = layout.video {
      videoViewTopConstraint = videoView.topAnchor.constraint(
        equalTo: contentView.topAnchor,
        constant: layout.videoContentViewTop
      )
      videoViewHeightConstraint = videoView.heightAnchor.constraint(equalToConstant: video.size.height)
      videoViewWidthConstraint = videoView.widthAnchor
        .constraint(equalToConstant: video.size.width)
      constraints.append(contentsOf: [
        videoViewTopConstraint!,
        videoViewHeightConstraint!,
        videoViewWidthConstraint!,
        videoView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: video.spacing.left),
      ])
    }
  }

  // MARK: - Constraints

  private var textViewWidthConstraint: NSLayoutConstraint?
  private var textViewHeightConstraint: NSLayoutConstraint?
  private var textViewTopConstraint: NSLayoutConstraint?
  private var textViewLeadingConstraint: NSLayoutConstraint?

  private var photoViewHeightConstraint: NSLayoutConstraint?
  private var photoViewWidthConstraint: NSLayoutConstraint?
  private var photoViewTopConstraint: NSLayoutConstraint?

  private var videoViewHeightConstraint: NSLayoutConstraint?
  private var videoViewWidthConstraint: NSLayoutConstraint?
  private var videoViewTopConstraint: NSLayoutConstraint?

  private var replyViewTopConstraint: NSLayoutConstraint?
  private var forwardHeaderTopConstraint: NSLayoutConstraint?

  private var documentViewTopConstraint: NSLayoutConstraint?

  private var attachmentsViewTopConstraint: NSLayoutConstraint?

  private var reactionViewWidthConstraint: NSLayoutConstraint!
  private var reactionViewHeightConstraint: NSLayoutConstraint!
  private var reactionViewTopConstraint: NSLayoutConstraint!
  private var reactionViewLeadingConstraint: NSLayoutConstraint?
  private var reactionViewTrailingConstraint: NSLayoutConstraint?

  private var timeViewTopConstraint: NSLayoutConstraint?
  private var timeViewBottomConstraint: NSLayoutConstraint?

  private var contentViewWidthConstraint: NSLayoutConstraint!
  private var contentViewHeightConstraint: NSLayoutConstraint!

  private var bubbleViewWidthConstraint: NSLayoutConstraint!
  private var bubbleViewHeightConstraint: NSLayoutConstraint!

  private var isInitialUpdateConstraint = true

  override func updateConstraints() {
    var skipUpdates = false
    if isInitialUpdateConstraint {
      setupConstraints()
      isInitialUpdateConstraint = false
      super.updateConstraints()
      skipUpdates = true
    }

    // Setup/update attachments view constraints
    if let attachments = props.layout.attachments {
      if let attachmentsViewTopConstraint {
        if attachmentsViewTopConstraint.constant != props.layout.attachmentsContentViewTop {
          attachmentsViewTopConstraint.constant = props.layout.attachmentsContentViewTop
        }
      } else if let attachmentsView {
        attachmentsViewTopConstraint = attachmentsView.topAnchor.constraint(
          equalTo: contentView.topAnchor,
          constant: props.layout.attachmentsContentViewTop
        )
        NSLayoutConstraint.activate([
          attachmentsViewTopConstraint!,
          attachmentsView.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: attachments.spacing.left
          ),
          attachmentsView.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor,
            constant: -attachments.spacing.right
          ),
        ])
      }
    }

    // From this point on, only updates happen (no setup)
    if skipUpdates {
      return
    }

    // Update constraints if changed
    if let text = props.layout.text,
       let textViewWidthConstraint,
       let textViewHeightConstraint,
       let textViewTopConstraint,
       let textViewLeadingConstraint
    {
      log.trace("Updating text view constraints for message \(text.size)")
      if textViewWidthConstraint.constant != text.size.width {
        textViewWidthConstraint.constant = text.size.width
      }

      if textViewHeightConstraint.constant != text.size.height {
        textViewHeightConstraint.constant = text.size.height
      }

      if textViewTopConstraint.constant != props.layout.textContentViewTop {
        textViewTopConstraint.constant = props.layout.textContentViewTop
      }

      if textViewLeadingConstraint.constant != text.spacing.left {
        textViewLeadingConstraint.constant = text.spacing.left
      }
    }

    if let reply = props.layout.reply,
       let replyViewTopConstraint
    {
      log.trace("Updating reply view constraints for message \(reply.size)")
      if replyViewTopConstraint.constant != props.layout.replyContentTop {
        replyViewTopConstraint.constant = props.layout.replyContentTop
      }
    }

    if let forwardHeader = props.layout.forwardHeader,
       let forwardHeaderTopConstraint
    {
      log.trace("Updating forward header constraints for message \(forwardHeader.size)")
      if forwardHeaderTopConstraint.constant != forwardHeader.spacing.top {
        forwardHeaderTopConstraint.constant = forwardHeader.spacing.top
      }
    }

    if let photo = props.layout.photo,
       let photoViewHeightConstraint,
       let photoViewWidthConstraint,
       let photoViewTopConstraint
    {
      log.trace("Updating photo view constraints for message \(photo.size)")
      if photoViewHeightConstraint.constant != photo.size.height {
        photoViewHeightConstraint.constant = photo.size.height
      }

      if photoViewWidthConstraint.constant != photo.size.width {
        photoViewWidthConstraint.constant = photo.size.width
      }

      if photoViewTopConstraint.constant != props.layout.photoContentViewTop {
        photoViewTopConstraint.constant = props.layout.photoContentViewTop
      }
    }

    if let video = props.layout.video,
       let videoViewHeightConstraint,
       let videoViewWidthConstraint,
       let videoViewTopConstraint
    {
      log.trace("Updating video view constraints for message \(video.size)")
      if videoViewHeightConstraint.constant != video.size.height {
        videoViewHeightConstraint.constant = video.size.height
      }

      if videoViewWidthConstraint.constant != video.size.width {
        videoViewWidthConstraint.constant = video.size.width
      }

      if videoViewTopConstraint.constant != props.layout.videoContentViewTop {
        videoViewTopConstraint.constant = props.layout.videoContentViewTop
      }
    } else if let video = props.layout.video {
      // Set up constraints if they didn't exist (e.g. view reused for a different message)
      videoViewTopConstraint = videoView.topAnchor.constraint(
        equalTo: contentView.topAnchor,
        constant: props.layout.videoContentViewTop
      )
      videoViewHeightConstraint = videoView.heightAnchor.constraint(equalToConstant: video.size.height)
      videoViewWidthConstraint = videoView.widthAnchor.constraint(equalToConstant: video.size.width)
      NSLayoutConstraint.activate([
        videoViewTopConstraint!,
        videoViewHeightConstraint!,
        videoViewWidthConstraint!,
        videoView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: video.spacing.left),
      ])
    }

    if let document = props.layout.document,
       let documentViewTopConstraint
    {
      log.trace("Updating document view constraints for message \(document.size)")
      let documentTop = props.layout.documentContentViewTop
      if documentViewTopConstraint.constant != documentTop {
        documentViewTopConstraint.constant = documentTop
      }
    }

    if let bubbleViewWidthConstraint,
       let bubbleViewHeightConstraint,
       let contentViewWidthConstraint,
       let contentViewHeightConstraint
    {
      let bubble = props.layout.bubble
      log.trace("Updating bubble view constraints for message \(bubble.size)")
      if bubbleViewWidthConstraint.constant != bubble.size.width {
        bubbleViewWidthConstraint.constant = bubble.size.width
      }

      if bubbleViewHeightConstraint.constant != bubble.size.height {
        bubbleViewHeightConstraint.constant = bubble.size.height
      }

      if contentViewWidthConstraint.constant != bubble.size.width {
        contentViewWidthConstraint.constant = bubble.size.width
      }

      if contentViewHeightConstraint.constant != bubble.size.height {
        contentViewHeightConstraint.constant = bubble.size.height
      }
    }

    // Update reaction constraints
    if let reactionsPlan = props.layout.reactions,
       let reactionViewWidthConstraint,
       let reactionViewHeightConstraint,
       let reactionViewTopConstraint
    {
      log.trace("Updating reactions view constraints for message \(reactionsPlan.size)")
      if reactionViewWidthConstraint.constant != reactionsPlan.size.width {
        reactionViewWidthConstraint.constant = reactionsPlan.size.width
      }

      if reactionViewHeightConstraint.constant != reactionsPlan.size.height {
        reactionViewHeightConstraint.constant = reactionsPlan.size.height
      }

      let reactionTopConstant = props.layout.reactionsOutsideBubble
        ? props.layout.reactionsOutsideBubbleTopInset
        : props.layout.reactionsViewTop
      if reactionViewTopConstraint.constant != reactionTopConstant {
        reactionViewTopConstraint.constant = reactionTopConstant
      }
      if props.layout.reactionsOutsideBubble, outgoing {
        if let reactionViewTrailingConstraint,
           reactionViewTrailingConstraint.constant != -reactionsPlan.spacing.right
        {
          reactionViewTrailingConstraint.constant = -reactionsPlan.spacing.right
        }
      } else {
        if let reactionViewLeadingConstraint,
           reactionViewLeadingConstraint.constant != reactionsPlan.spacing.left
        {
          reactionViewLeadingConstraint.constant = reactionsPlan.spacing.left
        }
      }
    } else if let reactionsView, let reactionsPlan = props.layout.reactions {
      // setup
      reactionViewHeightConstraint = reactionsView.heightAnchor.constraint(
        equalToConstant: reactionsPlan.size.height
      )
      reactionViewWidthConstraint = reactionsView.widthAnchor.constraint(
        equalToConstant: reactionsPlan.size.width
      )
      if props.layout.reactionsOutsideBubble {
        reactionViewTopConstraint = reactionsView.topAnchor.constraint(
          equalTo: bubbleView.bottomAnchor,
          constant: props.layout.reactionsOutsideBubbleTopInset
        )
        if outgoing {
          reactionViewTrailingConstraint = reactionsView.trailingAnchor.constraint(
            equalTo: bubbleView.trailingAnchor,
            constant: -reactionsPlan.spacing.right
          )
        } else {
          reactionViewLeadingConstraint = reactionsView.leadingAnchor.constraint(
            equalTo: bubbleView.leadingAnchor,
            constant: reactionsPlan.spacing.left
          )
        }
      } else {
        reactionViewTopConstraint = reactionsView.topAnchor.constraint(
          equalTo: contentView.topAnchor,
          constant: props.layout.reactionsViewTop
        )
        reactionViewLeadingConstraint = reactionsView.leadingAnchor.constraint(
          equalTo: contentView.leadingAnchor,
          constant: reactionsPlan.spacing.left
        )
      }
      NSLayoutConstraint.activate([
        reactionViewHeightConstraint,
        reactionViewWidthConstraint,
        reactionViewTopConstraint,
        reactionViewLeadingConstraint,
        reactionViewTrailingConstraint,
      ].compactMap(\.self))
    }

    if let time = props.layout.time {
      if props.layout.placesTimeAboveReactions {
        if let timeViewTopConstraint {
          if timeViewTopConstraint.constant != props.layout.timeViewTop {
            timeViewTopConstraint.constant = props.layout.timeViewTop
          }
        } else {
          timeViewBottomConstraint?.isActive = false
          timeViewBottomConstraint = nil
          timeViewTopConstraint = timeAndStateView.topAnchor.constraint(
            equalTo: contentView.topAnchor,
            constant: props.layout.timeViewTop
          )
          timeViewTopConstraint?.isActive = true
        }
      } else {
        let bottomConstant = -time.spacing.bottom
        if let timeViewBottomConstraint {
          if timeViewBottomConstraint.constant != bottomConstant {
            timeViewBottomConstraint.constant = bottomConstant
          }
        } else {
          timeViewTopConstraint?.isActive = false
          timeViewTopConstraint = nil
          timeViewBottomConstraint = timeAndStateView.bottomAnchor.constraint(
            equalTo: bubbleView.bottomAnchor,
            constant: bottomConstant
          )
          timeViewBottomConstraint?.isActive = true
        }
      }
    }
//    if hasReactions {
//      for (index, reaction) in reactionItems.enumerated() {
//        if let constraints = reactionItemConstraints[reaction] {
//          let newLeadingConstant = CGFloat(index) *
//            (props.layout.reactionsSize.width + props.layout.reactionsSpacing.left)
//          if constraints.leading.constant != newLeadingConstant {
//            constraints.leading.constant = newLeadingConstant
//          }
//
//          if constraints.width.constant != props.layout.reactionsSize.width {
//            constraints.width.constant = props.layout.reactionsSize.width
//          }
//
//          if constraints.height.constant != props.layout.reactionsSize.height {
//            constraints.height.constant = props.layout.reactionsSize.height
//          }
//        }
//      }
//    }

    super.updateConstraints()
  }

  private func setupMessageText() {
    guard hasText else { return }

    // Get display text which handles translations
    // TODO: Instead of using multiple computed properties, we should have do a single check here
    let translationText = fullMessage.translationText
    let translationEntities = fullMessage.translationEntities
    let text = translationText ?? fullMessage.message.text ?? ""
    let entities = translationEntities ?? fullMessage.message.entities

    // From Cache

    if
      let cachedAttributedString = CacheAttrs.shared.get(message: fullMessage)
    {
      let attributedString = cachedAttributedString
      textView.textStorage?.setAttributedString(attributedString)

      if useTextKit2 {
        textView.textContainer?.size = props.layout.text?.size ?? .zero
      } else {
        textView.textContainer?.size = props.layout.text?.size ?? .zero
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
      }
    }

    let codeBlockBackgroundColor = outgoing ? nil : textColor.withAlphaComponent(0.05)
    let inlineCodeBackgroundColor = outgoing ? nil : textColor.withAlphaComponent(0.06)

    /// Apply entities to text and create an NSAttributedString
    let attributedString = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: .init(
        // FIXME: Extract to a variable
        font: .systemFont(ofSize: props.layout.fontSize),
        textColor: textColor,
        linkColor: mentionColor,
        codeBlockBackgroundColor: codeBlockBackgroundColor,
        inlineCodeBackgroundColor: inlineCodeBackgroundColor
      )
    )

    // Detect and add links using centralized LinkDetector
    let linkMatches = LinkDetector.shared.applyLinkStyling(
      to: attributedString,
      linkColor: linkColor,
      cursor: NSCursor.pointingHand
    )

    // Store links for tap handling
    detectedLinks = linkMatches.map { (range: $0.range, url: $0.url) }

    textView.textStorage?.setAttributedString(attributedString)

    CacheAttrs.shared.set(message: fullMessage, value: attributedString)

    if useTextKit2 {
      textView.textContainer?.size = props.layout.text?.size ?? .zero
    } else {
      textView.textContainer?.size = props.layout.text?.size ?? .zero
      textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    }
  }

  func reflectBoundsChange(fraction _: CGFloat) {}

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    // Experimental in build 66
    // Adjust viewport instead of layouting
    if window != nil {
      // Register for both frame and bounds changes
//      NotificationCenter.default.addObserver(
//        self,
//        selector: #selector(handleBoundsChange),
//        name: NSView.frameDidChangeNotification,
//        object: enclosingScrollView?.contentView
//      )

      ////      // Also observe bounds changes
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleBoundsChange),
        name: NSView.boundsDidChangeNotification,
        object: enclosingScrollView?.contentView
      )

//      // Observe window resize notifications
//      NotificationCenter.default.addObserver(
//        self,
//        selector: #selector(handleBoundsChange),
//        name: NSWindow.didResizeNotification,
//        object: window
//      )
    }
  }

  private var prevWidth: CGFloat = 0

  // Fix a bug that when messages were out of viewport and came back during a live resize
  // text would not appear until the user ended live resize operation. Seems like in TextKit 2 calling layoutViewport
  // solves this.
  // The property `allowsNonContiguousLayout` also seems to fix this issue but it has two other issues:
  // 1. that forces textkit 1
  // 2. it adds a scroll jump everytime user resizes the window
  // which made it unsusable.
  // This approach still needs further testing.
  @objc private func handleBoundsChange(_ notification: Notification) {
    guard let scrollView = enclosingScrollView,
          let clipView = notification.object as? NSClipView else { return }

    boundsChange(scrollView: scrollView, clipView: clipView)
  }

  private var prevInViewport = false

  private func boundsChange(scrollView: NSScrollView, clipView: NSClipView) {
    guard feature_relayoutOnBoundsChange else { return }
    guard hasText else { return }
    // guard textView.inLiveResize else { return }

    let visibleRect = scrollView.documentVisibleRect
    let textViewRect = convert(bounds, to: clipView)
    let inViewport = visibleRect.insetBy(dx: 0.0, dy: 60.0).intersects(
      textViewRect
    )

    if !prevInViewport, inViewport {
      if textView.inLiveResize {
        textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
      }
      log
        .trace(
          "Layouting viewport for text view \(message.id)"
        )
      prevInViewport = true
    }
    if !inViewport {
      prevInViewport = false
    }
  }

  // MARK: - Context Menu

  private func setupContextMenu() {
    menu = createMenu(context: .message)
  }

  private func setupNotionAccessObserver() {
    notionAccessCancellable = NotionTaskService.shared.$hasAccess
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.setupContextMenu()
      }
  }

  @objc private func addReaction() {
    // Show reaction overlay
    showReactionOverlay()
  }

  @objc private func copyMessage() {
    NSPasteboard.general.clearContents()

    // Old
    // NSPasteboard.general.setString(message.text ?? "", forType: .string)

    // Copy Translation
    NSPasteboard.general
      .setString(fullMessage.displayText ?? "", forType: .string)
  }

  @objc private func copyMessageWithEntities() {
    struct DebugMessageContent<Entities: Encodable>: Encodable {
      let text: String?
      let entities: Entities?
    }

    let payload = DebugMessageContent(
      text: fullMessage.translationText ?? message.text,
      entities: fullMessage.translationEntities ?? message.entities
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

    NSPasteboard.general.clearContents()

    do {
      let data = try encoder.encode(payload)
      if let string = String(data: data, encoding: .utf8) {
        NSPasteboard.general.setString(string, forType: .string)
      } else {
        log.error("Failed to encode message debug payload: invalid UTF-8")
        NSPasteboard.general.setString(fullMessage.displayText ?? "", forType: .string)
      }
    } catch {
      log.error("Failed to encode message debug payload", error: error)
      NSPasteboard.general.setString(fullMessage.displayText ?? "", forType: .string)
    }
  }

  @objc private func copyLinkAddress(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }

  @objc private func deleteMessage() {
    // Delete message
    Task(priority: .userInitiated) { @MainActor in
      try await Api.realtime.send(.deleteMessages(
        messageIds: [message.messageId],
        peerId: message.peerId,
        chatId: message.chatId
      ))
    }
  }

  @objc private func reply() {
    let state = ChatsManager
      .get(
        for: fullMessage.peerId,
        chatId: fullMessage.chatId
      )

    state.setReplyingToMsgId(fullMessage.message.messageId)
  }

  @objc private func forwardMessage() {
    guard let window, let presentingController = window.contentViewController else { return }

    weak var weakHostingController: NSViewController?
    let rootView = ForwardMessagesSheet(messages: [fullMessage]) { [weak self] destination, selection in
      guard let destinationChatId = destination.dialog.chatId ?? destination.chat?.id else {
        Log.shared.error("Forward nav failed: missing destination chat id")
        return
      }
      let destinationPeer = destination.peerId
      let state = ChatsManager.get(for: destinationPeer, chatId: destinationChatId)
      state.setForwardingMessages(
        fromPeerId: selection.fromPeerId,
        sourceChatId: selection.sourceChatId,
        messageIds: selection.messageIds
      )

      self?.openChat(peer: destinationPeer)
      NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
    } onClose: { [weak presentingController] in
      guard let hostingController = weakHostingController else { return }
      presentingController?.dismiss(hostingController)
    }
    .appDatabase(AppDatabase.shared)

    let hostingController = NSHostingController(rootView: AnyView(rootView))
    weakHostingController = hostingController
    hostingController.title = "Forward"
    hostingController.preferredContentSize = NSSize(width: 480, height: 560)
    presentingController.presentAsSheet(hostingController)
    DispatchQueue.main.async { [weak hostingController] in
      guard let window = hostingController?.view.window else { return }
      window.title = "Forward"
      window.styleMask.insert(.closable)
      window.standardWindowButton(.closeButton)?.isHidden = false
    }
  }

  private func openChat(peer: Peer) {
    if let nav2 = dependencies?.nav2 {
      nav2.navigate(to: .chat(peer: peer))
    } else {
      Nav.main.open(.chat(peer: peer))
    }
  }

  @objc private func editMessage() {
    let state = ChatsManager
      .get(
        for: fullMessage.peerId,
        chatId: fullMessage.chatId
      )

    state.setEditingMsgId(fullMessage.message.messageId)
  }

  @objc private func handleWillDo() {
    guard let window else { return }

    Task { @MainActor in
      let spaceId: Int64? = if message.peerId.isThread {
        try? Chat.getByPeerId(peerId: message.peerId)?.spaceId
      } else {
        nil
      }

      await NotionTaskCoordinator.shared.handleWillDo(
        message: message,
        spaceId: spaceId,
        window: window
      )
    }
  }

  @objc private func handleCreateLinearIssue() {
    guard let window else { return }

    Task { @MainActor in
      await LinearIssueCoordinator.shared.handleCreateLinearIssue(message: message, window: window)
    }
  }

  @objc private func saveDocument() {
    guard let documentInfo = fullMessage.documentInfo else { return }
    guard let window else { return }

    // Get the source file URL
    let cacheDirectory = FileHelpers.getLocalCacheDirectory(for: .documents)
    guard let localPath = documentInfo.document.localPath else {
      Task { @MainActor in
        ToastCenter.shared.showError("File isn’t available")
      }
      return
    }
    let sourceURL = cacheDirectory.appendingPathComponent(localPath)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      Task { @MainActor in
        ToastCenter.shared.showError("File isn’t downloaded yet")
      }
      return
    }

    // Get the Downloads directory
    let fileManager = FileManager.default
    let downloadsURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!

    // Get the filename
    let fileName = documentInfo.document.fileName ?? "Unknown File"

    // Create a save panel
    let savePanel = NSSavePanel()
    savePanel.nameFieldStringValue = fileName
    savePanel.directoryURL = downloadsURL
    savePanel.canCreateDirectories = true

    savePanel.beginSheetModal(for: window) { [weak self] response in
      if response == .OK, let destinationURL = savePanel.url {
        do {
          if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
          }
          try fileManager.copyItem(at: sourceURL, to: destinationURL)
          Task { @MainActor in
            ToastCenter.shared.showSuccess("File saved")
          }
          NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
          self?.log.error("Error saving document", error: error)
          Task { @MainActor in
            ToastCenter.shared.showError("Failed to save file")
          }
        }
      }
    }
  }

  override func willOpenMenu(_: NSMenu, with _: NSEvent) {
    // Apply selection style when menu is about to open
    layer?.backgroundColor = NSColor.darkGray
      .withAlphaComponent(0.05).cgColor
  }

  override func didCloseMenu(_: NSMenu, with _: NSEvent?) {
    // Remove selection style when menu closes
    layer?.backgroundColor = nil
  }

  // MARK: - View Updates

  private func updatePropsAndUpdateLayout(
    props: MessageViewProps,
    disableTextRelayout _: Bool = false,
    animate: Bool = false
  ) {
    // update internal props (must update so contentView is recalced)
    self.props = props

    if textView.textContainer?.size != props.layout.text?.size ?? .zero {
      log.trace("updating size for text in msg \(message.id)")
      textView.textContainer?.size = props.layout.text?.size ?? .zero
    }

    layoutSubtreeIfNeeded()

    needsUpdateConstraints = true

    if animate {
      // Animate the changes
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        context.allowsImplicitAnimation = true

        // self.animator().layoutSubtreeIfNeeded()
        self.layoutSubtreeIfNeeded()
      } completionHandler: { [weak self] in
        // Completion block
        DispatchQueue.main.async {
          // Fixes text display issues going blank
          self?.textView.textLayoutManager?.textViewportLayoutController
            .layoutViewport()
        }
      }
    }
  }

  func updateTextAndSize(fullMessage: FullMessage, props: MessageViewProps, animate: Bool = false) {
    log.trace(
      "Updating message view content. from: \(self.fullMessage.message.messageId) to: \(fullMessage.message.messageId)"
    )

    let prev = self.fullMessage

    prevInViewport = false

    // Ensure media views exist before constraint updates when reusing the view
    if props.layout.video != nil, videoView.superview == nil {
      contentView.addSubview(videoView)
    }

    // update internal props
    self.fullMessage = fullMessage

    // Update related message for reply view
    if hasReply {
      replyView.setRelatedMessage(fullMessage.message)
      if let embeddedMessage = fullMessage.repliedToMessage {
        replyView.update(with: embeddedMessage, kind: .replyInMessage)
      }
    }

    // Update props and reflect changes
    updatePropsAndUpdateLayout(props: props, disableTextRelayout: true, animate: animate)

    // Reactions
    // TODO: Reactions are not updating as expected
    updateReactions(prev: prev, next: fullMessage, props: props)

    // Text
    setupMessageText()

    // Update bubble background
    bubbleView.backgroundColor = bubbleBackgroundColor

    if hasForwardHeader {
      forwardHeaderLabel.textColor = forwardHeaderTextColor
      forwardHeaderLabel.stringValue = forwardHeaderText
    }

    // Photo
    if hasPhoto {
      photoView.update(with: fullMessage)
    }

    // Video
    if hasVideo {
      if videoView.superview == nil {
        contentView.addSubview(videoView)
      }
      videoView.update(with: fullMessage)
    }

    // Document
    if hasDocument, let documentView {
      if let documentInfo = fullMessage.documentInfo {
        documentView.update(with: documentInfo)
      }
    }

    if hasAttachments {
      if let attachmentsView {
        attachmentsView.configure(attachments: fullMessage.attachments)
      } else {
        attachmentsView = createAttachmentsView()
        contentView.addSubview(attachmentsView!)
      }
    } else {
      attachmentsView?.removeFromSuperview()
      attachmentsView = nil
      attachmentsViewTopConstraint = nil
    }

    // Update time and state
    timeAndStateView.updateMessage(fullMessage, overlay: isTimeOverlay)

    // Ensure swipe UI is reset if message cannot be replied to
    if !self.fullMessage.canReply {
      layer?.transform = CATransform3DIdentity
      swipeAnimationView?.alphaValue = 0
      isSwipeInProgress = false
      hasTriggerHapticFeedback = false
      didReachThreshold = false
    }

    // Experimental: I wanted to add this for external task attachments when created, but I'm just adding it here.
    // Force update constraints
    needsUpdateConstraints = true

    DispatchQueue.main.async(qos: .utility) { [weak self] in
      // As the message changes here, we need to update everything related to that. Otherwise we get wrong context menu.
      self?.setupContextMenu()
    }
  }

  func updateSize(props: MessageViewProps) {
    // update props and reflect changes
    updatePropsAndUpdateLayout(
      props: props,
      // disableTextRelayout: props.layout.singleLine // Quick hack to reduce such re-layouts
      disableTextRelayout: true
    )

    // if hasReactions {
    updateReactionsSizes()
    // }
  }

  private func setTimeAndStateVisibility(visible _: Bool) {
//    NSAnimationContext.runAnimationGroup { context in
//      context.duration = visible ? 0.05 : 0.05
//      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
//      context.allowsImplicitAnimation = true
//      timeAndStateView.layer?.opacity = visible ? 1 : 0
//    }
  }

  // MARK: - Actions

  // ---
  private var notificationObserver: NSObjectProtocol?
  private var scrollState: MessageListScrollState = .idle {
    didSet {
      if hasPhoto {
        if scrollState == .idle {
          photoView.setIsScrolling(false)
        } else {
          photoView.setIsScrolling(true)
        }
      }
      if hasVideo {
        if scrollState == .idle {
          videoView.setIsScrolling(false)
        } else {
          videoView.setIsScrolling(true)
        }
      }
    }
  }

  private var hoverTrackingArea: NSTrackingArea?
  private func setupScrollStateObserver() {
    notificationObserver = NotificationCenter.default.addObserver(
      forName: .messageListScrollStateDidChange,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let state = notification.userInfo?["state"] as? MessageListScrollState else { return }
      self?.handleScrollStateChange(state)
    }
  }

  // MARK: - Swipe to Reply

  // Track swipe state
  private var isSwipeInProgress = false
  private var swipeOffset: CGFloat = 0
  private var swipeAnimationView: NSView?
  private var hasTriggerHapticFeedback = false
  private var swipeThreshold: CGFloat = 50.0
  private var didReachThreshold = false

  override func scrollWheel(with event: NSEvent) {
    // Do not allow swipe-to-reply if message cannot be replied to
    if !fullMessage.canReply {
      // Ensure UI is reset and pass through
      layer?.transform = CATransform3DIdentity
      swipeAnimationView?.alphaValue = 0
      isSwipeInProgress = false
      hasTriggerHapticFeedback = false
      didReachThreshold = false
      super.scrollWheel(with: event)
      return
    }
    // Only handle horizontal scrolling with two fingers
    if event.phase == .began, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
      // Start of a horizontal scroll
      isSwipeInProgress = true
      swipeOffset = 0
      hasTriggerHapticFeedback = false
      didReachThreshold = false

      // Create animation view if needed
      if swipeAnimationView == nil {
        swipeAnimationView = createReplyIndicator()
        addSubview(swipeAnimationView!)
        swipeAnimationView?.alphaValue = 0
      }

      // Position the animation view
      if let animView = swipeAnimationView {
        let yPosition = bubbleView.bounds.midY - animView.bounds.height / 2
        animView.frame.origin = NSPoint(x: bounds.width, y: yPosition)
      }
    }

    if isSwipeInProgress {
      // Update swipe offset based on scroll delta
      // Note: scrollingDeltaX is positive for right-to-left swipes on some systems
      // We need to ensure we're getting a negative value for left swipes
      let deltaX = event.scrollingDeltaX

      // Adjust the swipe offset - we want negative values for left swipes
      swipeOffset += deltaX

      // Only handle left swipes (negative swipeOffset)
      if swipeOffset < 0 {
        // Calculate swipe progress (0 to 1)
        let progress = min(1.0, abs(swipeOffset) / swipeThreshold)

        // Update position using layer transform on self
        let maxOffset: CGFloat = 40.0
        let offset = -min(maxOffset, abs(swipeOffset)) // Negative for left movement

        // Apply transform to root view layer
        wantsLayer = true
        let transform = CATransform3DMakeTranslation(offset, 0, 0)
        layer?.transform = transform

        // Update animation view
        swipeAnimationView?.alphaValue = progress

        // Track if we've reached the threshold
        let hasReachedThreshold = abs(swipeOffset) > swipeThreshold

        // Only trigger haptic feedback when first crossing the threshold
        if hasReachedThreshold, !didReachThreshold {
          NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
          didReachThreshold = true
          hasTriggerHapticFeedback = true
        } else if !hasReachedThreshold, didReachThreshold {
          // We've moved back below the threshold
          didReachThreshold = false
        }
      } else {
        // Reset for right swipes
        layer?.transform = CATransform3DIdentity
        swipeAnimationView?.alphaValue = 0
      }

      // End of swipe gesture
      if event.phase == .ended || event.phase == .cancelled {
        isSwipeInProgress = false

        let direction = swipeOffset > 0 ? "right" : "left"

        // Check if swipe was far enough to trigger reply
        if abs(swipeOffset) > swipeThreshold, direction == "left" {
          // Guard again in case state changed mid-gesture
          guard fullMessage.canReply else {
            // Reset and exit
            NSAnimationContext.runAnimationGroup { context in
              context.duration = 0.2
              context.allowsImplicitAnimation = true
              context.timingFunction = CAMediaTimingFunction(name: .easeOut)
              self.layer?.transform = CATransform3DIdentity
              swipeAnimationView?.animator().alphaValue = 0
            }
            hasTriggerHapticFeedback = false
            didReachThreshold = false
            return
          }
          focusWindowIfNeeded()
          Task(priority: .userInitiated) { @MainActor in self.reply() }

          // Animate back with spring effect
          NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.layer?.transform = CATransform3DIdentity
            swipeAnimationView?.animator().alphaValue = 0
          }) {}
        } else {
          // Not far enough, just animate back
          NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.layer?.transform = CATransform3DIdentity
            swipeAnimationView?.animator().alphaValue = 0
          }
        }

        // Reset state
        hasTriggerHapticFeedback = false
        didReachThreshold = false
      }
    } else {
      // Pass the event to super if we're not handling it
      super.scrollWheel(with: event)
    }
  }

  private func focusWindowIfNeeded() {
    guard let window else { return }
    if !NSApplication.shared.isActive {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    if !window.isKeyWindow {
      window.makeKeyAndOrderFront(nil)
    }
  }

  private func createReplyIndicator() -> NSView {
    // Create a smaller indicator (24x24 pixels)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    container.wantsLayer = true
    container.layer?.cornerRadius = 12
    container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor

    // Add reply icon (smaller size)
    let iconView = NSImageView(frame: NSRect(x: 4, y: 4, width: 16, height: 16))
    if let replyImage = NSImage(systemSymbolName: "arrowshape.turn.up.left.fill", accessibilityDescription: "Reply") {
      iconView.image = replyImage
      iconView.contentTintColor = NSColor.controlAccentColor
      container.addSubview(iconView)
    }

    return container
  }

  func reset() {
    // Cancel translation state observation
    translationStateCancellable?.cancel()
    translationStateCancellable = nil

    // Remove shine effect
    shineEffectView?.stopAnimation()
    shineEffectView?.removeFromSuperview()
    shineEffectView = nil

    // Re-setup translation state observation
    setupTranslationStateObservation()
  }

  @objc private func cancelMessage() {
    Log.shared.debug("Canceling message")
    if let transactionId = message.transactionId, !transactionId.isEmpty {
      Transactions.shared.cancel(transactionId: transactionId)
    } else {
      // try v2
      let randomId = message.randomId
      Task {
        Api.realtime.cancelTransaction(where: {
          guard $0.transaction.method == .sendMessage else { return false }
          guard case let .sendMessage(input) = $0.transaction.input else { return false }
          return input.randomID == randomId
        })
      }
    }
  }

  @objc private func resendMessage() {
    Task {
      var mediaItems: [FileMediaItem] = []

      if let photoInfo = fullMessage.photoInfo {
        mediaItems.append(.photo(photoInfo))
      }

      if let videoInfo = fullMessage.videoInfo {
        mediaItems.append(.video(videoInfo))
      }

      if let documentInfo = fullMessage.documentInfo {
        mediaItems.append(.document(documentInfo))
      }

      let messageId = self.message.messageId
      let chatId = self.message.chatId
      _ = try? await AppDatabase.shared.dbWriter.write { db in
        try Message.deleteMessages(db, messageIds: [messageId], chatId: chatId)
      }

      await MainActor.run {
        MessagesPublisher.shared
          .messagesDeleted(messageIds: [message.messageId], peer: message.peerId)
      }

      if mediaItems.isEmpty {
        try await Api.realtime.send(
          .sendMessage(
            text: message.text ?? "",
            peerId: message.peerId,
            chatId: message.chatId,
            replyToMsgId: message.repliedToMessageId,
            isSticker: message.isSticker,
            entities: message.entities
          )
        )
      } else {
        await Transactions.shared.mutate(
          transaction: .sendMessage(.init(
            text: message.text,
            peerId: message.peerId,
            chatId: message.chatId,
            mediaItems: mediaItems,
            replyToMsgId: message.repliedToMessageId,
            isSticker: message.isSticker,
            entities: message.entities
          ))
        )
      }
    }
  }
}

// MARK: - Tracking Area & Hover

extension MessageViewAppKit {
  func setScrollState(_ state: MessageListScrollState) {
    handleScrollStateChange(state)
  }

  private func handleScrollStateChange(_ state: MessageListScrollState) {
    scrollState = state
    switch state {
      case .scrolling:
        // Clear hover state
        updateHoverState(false)
      case .idle:
        break
        // Re-enable hover state if needed
        // TODO: How can I check if mouse is inside the view?
        // addHoverTrackingArea()
    }
  }

  var shouldAlwaysShowTimeAndState: Bool {
    message.status == .sending || message.status == .failed
  }

  private func updateHoverState(_ isHovered: Bool) {
    isMouseInside = isHovered
  }

  func removeHoverTrackingArea() {
    if let hoverTrackingArea {
      removeTrackingArea(hoverTrackingArea)
    }
  }

  func addHoverTrackingArea() {
    removeHoverTrackingArea()
    hoverTrackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(hoverTrackingArea!)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    guard scrollState == .idle else { return }
    updateHoverState(true)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    updateHoverState(false)
  }
}

// MARK: - NSGestureRecognizerDelegate

extension MessageViewAppKit: NSGestureRecognizerDelegate {
  func gestureRecognizer(_: NSGestureRecognizer, shouldReceive event: NSEvent) -> Bool {
    guard let reactionsView else { return true }

    let locationInSelf = convert(event.locationInWindow, from: nil)
    let locationInReactions = reactionsView.convert(locationInSelf, from: self)
    if reactionsView.bounds.contains(locationInReactions) {
      return false
    }

    return true
  }
}

// MARK: - NSTextViewDelegate

extension MessageViewAppKit: NSTextViewDelegate {
  func textView(_: NSTextView, menu: NSMenu, for _: NSEvent, at charIndex: Int) -> NSMenu? {
    let linkURL = linkURLForContextMenu(at: charIndex)
    return createMenu(context: .textView, nativeMenu: menu, linkURL: linkURL)
  }

  // func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
  //   // Handle our custom detected links
  //   handleLinkClick(at: charIndex)
  //   return true
  // }
}

extension MessageViewAppKit: NSMenuDelegate {
  enum MenuContext {
    case message
    case textView
  }

  func createMenu(context: MenuContext, nativeMenu: NSMenu? = nil, linkURL: URL? = nil) -> NSMenu {
    let menu = NSMenu()

    let regularMessage = message.status != .sending && message.status != .failed

    // Reply
    if regularMessage {
      let replyItem = NSMenuItem(title: "Reply", action: #selector(reply), keyEquivalent: "r")
      replyItem.image = NSImage(systemSymbolName: "arrowshape.turn.up.left", accessibilityDescription: "Reply")
      menu.addItem(replyItem)

      let forwardItem = NSMenuItem(title: "Forward", action: #selector(forwardMessage), keyEquivalent: "")
      forwardItem.image = NSImage(systemSymbolName: "arrowshape.turn.up.right", accessibilityDescription: "Forward")
      menu.addItem(forwardItem)
    }

    // Edit
    if message.out == true, message.status == .sent {
      let editItem = NSMenuItem(title: "Edit", action: #selector(editMessage), keyEquivalent: "e")
      editItem.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Edit")
      menu.addItem(editItem)
    }

    if regularMessage {
      // Add reaction action
      let addReactionItem = NSMenuItem(title: "Add Reaction...", action: #selector(addReaction), keyEquivalent: "e")
      addReactionItem.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Add Reaction")
      menu.addItem(addReactionItem)
    }

    // Integrations section (separator above + below)
    var integrationItems: [NSMenuItem] = []

    if regularMessage, NotionTaskService.shared.hasAccess {
      let willDoItem = NSMenuItem(title: "Will Do", action: #selector(handleWillDo), keyEquivalent: "")
      willDoItem.image = NSImage(systemSymbolName: "circle.badge.plus", accessibilityDescription: "Create Notion Task")
      integrationItems.append(willDoItem)
    }

    if regularMessage, hasText {
      if message.peerId.isThread {
        if let spaceId = (try? Chat.getByPeerId(peerId: message.peerId)?.spaceId) {
          if LinearIntegrationService.shared.isConnected(spaceId: spaceId) == nil {
            // Warm the cache for future menus. We'll only show the action once we know Linear is connected.
            LinearIntegrationService.shared.refresh(spaceId: spaceId)
          }

          if LinearIntegrationService.shared.isConnected(spaceId: spaceId) == true {
            let createLinearIssueItem = NSMenuItem(
              title: "Create Linear Issue",
              action: #selector(handleCreateLinearIssue),
              keyEquivalent: ""
            )
            createLinearIssueItem.image = NSImage(
              systemSymbolName: "circle.badge.plus",
              accessibilityDescription: "Create Linear Issue"
            )
            integrationItems.append(createLinearIssueItem)
          }
        }
      } else {
        if LinearIntegrationService.shared.isConnectedAnySpace() == nil {
          // Warm the cache for future menus. We'll only show the action once we know Linear is connected.
          LinearIntegrationService.shared.refreshAnySpace()
        }

        if LinearIntegrationService.shared.isConnectedAnySpace() == true {
          let createLinearIssueItem = NSMenuItem(
            title: "Create Linear Issue",
            action: #selector(handleCreateLinearIssue),
            keyEquivalent: ""
          )
          createLinearIssueItem.image = NSImage(
            systemSymbolName: "circle.badge.plus",
            accessibilityDescription: "Create Linear Issue"
          )
          integrationItems.append(createLinearIssueItem)
        }
      }
    }

    if !integrationItems.isEmpty {
      if !menu.items.isEmpty {
        menu.addItem(NSMenuItem.separator())
      }
      integrationItems.forEach { menu.addItem($0) }
      menu.addItem(NSMenuItem.separator())
    }

    var rendersCopyText = false

    if context == .textView, let linkURL {
      let copyLinkItem = NSMenuItem(
        title: "Copy Link Address",
        action: #selector(copyLinkAddress),
        keyEquivalent: ""
      )
      copyLinkItem.target = self
      copyLinkItem.representedObject = linkURL
      copyLinkItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Copy Link")
      menu.addItem(copyLinkItem)
    }

    // Add native copy for selected text if in text view context
    if context == .textView,
       let nativeMenu,
       let nativeCopyItem = nativeMenu.items.first(where: { $0.title == "Copy" })
    {
      let newItem = nativeCopyItem.copy() as! NSMenuItem
      newItem.title = "Copy Selected Text"
      menu.addItem(newItem)
      rendersCopyText = true
    }

    // Add copy message action for text
    if hasText {
      let copyItem = NSMenuItem(title: "Copy Text", action: #selector(copyMessage), keyEquivalent: "c")
      if !rendersCopyText {
        copyItem.image = NSImage(systemSymbolName: "document.on.document", accessibilityDescription: "Copy")
        rendersCopyText = true
      }
      menu.addItem(copyItem)

      if canCopyMessageWithEntities {
        let debugCopyItem = NSMenuItem(
          title: "Copy Message + Entities",
          action: #selector(copyMessageWithEntities),
          keyEquivalent: ""
        )
        menu.addItem(debugCopyItem)
      }
    }

    // Add photo actions
    if hasPhoto {
      let copyItem = NSMenuItem(title: "Copy Image", action: #selector(photoView.copyImage), keyEquivalent: "i")
      copyItem.target = photoView
      copyItem.isEnabled = true
      copyItem.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Copy Image")
      menu.addItem(copyItem)
    }

    if hasPhoto {
      menu.addItem(NSMenuItem.separator())
      let saveItem = NSMenuItem(title: "Save Image", action: #selector(photoView.saveImage), keyEquivalent: "m")
      saveItem.target = photoView
      saveItem.isEnabled = true
      saveItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save Image")
      menu.addItem(saveItem)
    }

    // Add video actions
    if hasVideo {
      menu.addItem(NSMenuItem.separator())
      let openItem = NSMenuItem(title: "Open Video", action: #selector(videoView.openQuickLook), keyEquivalent: "v")
      openItem.target = videoView
      openItem.isEnabled = true
      openItem.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "Play")
      menu.addItem(openItem)

      let saveItem = NSMenuItem(
        title: "Save Video",
        action: #selector(videoView.saveVideo),
        keyEquivalent: "s"
      )
      saveItem.target = videoView
      saveItem.isEnabled = true
      saveItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save Video")
      menu.addItem(saveItem)
    }

    // Add document actions
    if hasDocument {
      menu.addItem(NSMenuItem.separator())
      let saveItem = NSMenuItem(title: "Save Document", action: #selector(saveDocument), keyEquivalent: "s")
      saveItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save Document")
      menu.addItem(saveItem)
    }

    // Add other native menu items if in text view context
    if context == .textView, let nativeMenu {
      menu.addItem(NSMenuItem.separator())

      for item in nativeMenu.items {
        if item.title.hasPrefix("Look Up") {
          let newItem = item.copy() as! NSMenuItem
          newItem.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Save Document")
          menu.addItem(newItem)
        }

        if item.title.hasPrefix("Translate") {
          let newItem = item.copy() as! NSMenuItem
          menu.addItem(newItem)
        }
      }
    }

    menu.addItem(NSMenuItem.separator())

    // Resend for failed messages
    if message.status == .failed {
      let resendItem = NSMenuItem(title: "Resend", action: #selector(resendMessage), keyEquivalent: "")
      resendItem.target = self
      resendItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Resend")
      menu.addItem(resendItem)
    }

    // Delete or cancel button
    if message.status == .sending {
      let cancelItem = NSMenuItem(title: "Cancel", action: #selector(cancelMessage), keyEquivalent: "delete")
      cancelItem.target = self
      cancelItem.image = NSImage(systemSymbolName: "x.circle", accessibilityDescription: "Cancel")
      menu.addItem(cancelItem)
    } else {
      let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteMessage), keyEquivalent: "delete")
      deleteItem.target = self
      deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
      menu.addItem(deleteItem)
    }

    /// If message is edited, show edit date in context menu
    if let editDate = message.editDate {
      menu.addItem(NSMenuItem.separator())
      let formatted = DateFormatter.localizedString(from: editDate, dateStyle: .medium, timeStyle: .short)
      let editDateItem = NSMenuItem(title: "Edited \(formatted)", action: nil, keyEquivalent: "")
      editDateItem.isEnabled = false
      menu.addItem(editDateItem)
    }

    #if DEBUG
    menu.addItem(NSMenuItem.separator())

    // Add debug items
    let idItem = NSMenuItem(title: "ID: \(message.id)", action: nil, keyEquivalent: "")
    idItem.isEnabled = false
    menu.addItem(idItem)

    let indexItem = NSMenuItem(
      title: "Index: \(props.index?.description ?? "?")",
      action: nil,
      keyEquivalent: ""
    )
    indexItem.isEnabled = false
    menu.addItem(indexItem)

    #endif

    menu.delegate = self
    return menu
  }
}

// Helper extension for constraint priorities
private extension NSLayoutConstraint {
  func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
    self.priority = priority
    return self
  }
}

//// Implement viewport constraint
extension MessageViewAppKit: NSTextViewportLayoutControllerDelegate {
  func textViewportLayoutController(
    _ textViewportLayoutController: NSTextViewportLayoutController,
    configureRenderingSurfaceFor textLayoutFragment: NSTextLayoutFragment
  ) {
    prevDelegate?.textViewportLayoutController(
      textViewportLayoutController,
      configureRenderingSurfaceFor: textLayoutFragment
    )
  }

  func textViewportLayoutControllerWillLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
    prevDelegate?.textViewportLayoutControllerWillLayout?(textViewportLayoutController)
  }

  func textViewportLayoutControllerDidLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
    prevDelegate?.textViewportLayoutControllerDidLayout?(textViewportLayoutController)
  }

  func viewportBounds(for _: NSTextViewportLayoutController) -> CGRect {
    // During resize, we need to be more aggressive with the viewport size
    let visibleRect = enclosingScrollView?.documentVisibleRect ?? textView.visibleRect

    // Create a larger viewport during resize to ensure text remains visible
    let expandedRect = visibleRect.insetBy(dx: -100, dy: -500)

    // Convert to text view coordinates if needed
    let textViewRect = textView.convert(expandedRect, from: enclosingScrollView?.contentView)

    return textViewRect
  }
}
