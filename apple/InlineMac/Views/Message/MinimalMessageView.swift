// MessageView.swift
import AppKit
import Auth
import Combine
import Foundation
import GRDB
import InlineKit
import InlineMacUI
import struct InlineProtocol.MessageAction
import struct InlineProtocol.MessageActionRow
import struct InlineProtocol.MessageEntities
import struct InlineProtocol.MessageEntity
import InlineUI
import Logger
import Nuke
import NukeUI
import SwiftUI
import TextProcessing
import Throttler
import Translation

private enum MessageActionInvokeError: Error {
  case invalidResponse
}

private enum ReplyThreadOpenError: Error {
  case invalidResponse
}

private enum ReplyThreadOpenSource {
  case menu
  case threadSummary
}

class MinimalMessageViewAppKit: NSView {
  private let feature_relayoutOnBoundsChange = true
  private let log = Log.scoped("MinimalMessageView", enableTracing: false)
  static let avatarSize: CGFloat = MessageSizeCalculator.minimalAvatarSize
  /// Built the first time this cell shows a message with an Ack. Most messages never have one,
  /// and the pill (symbol image, label, layer) was a fixed part of every cell's construction.
  private var acknowledgementView: MessageAcknowledgementView?
  /// "Sent via Codex" under the last message of an agent's run.
  private var viaFooterLabel: NSTextField?
  private(set) var fullMessage: FullMessage
  private let dependencies: AppDependencies?
  private var props: MessageViewProps
  private var translationStateCancellable: AnyCancellable?
  private var messageActionLoadingCancellable: AnyCancellable?
  private var messageActionAnsweredCancellable: AnyCancellable?
  private var messageActionGrantsCancellable: AnyCancellable?
  private var didResolveMessageSpaceId = false
  private var isResolvingMessageSpaceId = false
  private var resolvedMessageSpaceId: Int64?
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
    guard let currentUserId = Auth.shared.getCurrentUserId() else { return false }
    return currentUserId == 1_900 || currentUserId == 1_600
  }

  private static var isDebugBuild: Bool {
    #if DEBUG
    return true
    #else
    return false
    #endif
  }

  private func isMessagePinned() -> Bool {
    message.pinned == true
  }

  private var isDM: Bool {
    props.isDM
  }

  private var chatHasAvatar: Bool {
    true
  }

  private var showsAvatar: Bool {
    chatHasAvatar && props.layout.hasAvatar
  }

  private var showsInlineAvatar: Bool {
    showsAvatar && !usesAvatarOverlay
  }

  private var usesAvatarOverlay: Bool {
    props.usesAvatarOverlay && props.renderStyle == .minimal && AppConfig.macMessageAvatarOverlayEnabled
  }

  private var avatarUserInfo: UserInfo {
    if let senderInfo = fullMessage.senderInfo {
      return senderInfo
    }

    if outgoing {
      if let currentUserInfo = dependencies?.rootData?.currentUserInfo {
        return currentUserInfo
      }
    }

    return .deleted
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

  private var isAnchorMessage: Bool {
    props.interactionMode == .threadAnchor
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

  private var hasVoiceInDocumentSlot: Bool {
    message.hasVoice
  }

  private var canSaveLoadedVoice: Bool {
    hasVoiceInDocumentSlot && VoiceMessageAudioSaver.canSave(message)
  }

  private var hasActualDocument: Bool {
    fullMessage.documentInfo != nil
  }

  private var hasReply: Bool {
    props.layout.hasReply
  }

  private var hasReplyThreadSummary: Bool {
    props.layout.hasReplyThreadSummary
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

  private var hasAcknowledgement: Bool {
    props.layout.hasAcknowledgement
  }

  /// Matches MessageSizeCalculator.showsMinimalViaFooter, which reserves the row.
  private var showsViaFooter: Bool {
    props.lastInGroup && props.interactionMode != .threadAnchor && fullMessage.message.via != nil
  }

  private var textWidth: CGFloat {
    props.layout.text?.size.width ?? 1.0
  }

  private var contentWidth: CGFloat {
    props.layout.bubble.size.width
  }

  private var textColor: NSColor {
    .labelColor
  }

  private var forwardHeaderTextColor: NSColor {
    return .controlAccentColor
  }

  private var forwardHeaderTitle: String {
    if message.forwardFromPeerThreadId != nil {
      return fullMessage.forwardFromChatInfo?.humanReadableTitle ?? "Untitled"
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

  static func textColor(outgoing _: Bool) -> NSColor {
    .labelColor
  }

  static func linkColor(outgoing _: Bool) -> NSColor {
    Theme.accentColor
  }

  private var emojiMessage: Bool {
    props.layout.emojiMessage
  }

  private var bubbleBackgroundColor: NSColor {
    .clear
  }

  private var linkColor: NSColor {
    Self.linkColor(outgoing: outgoing)
  }

  private var secondaryTextColor: NSColor {
    .secondaryLabelColor
  }

  private var richTextPalette: ProcessEntities.Configuration.Palette {
    .init(
      primaryColor: textColor,
      linkColor: linkColor,
      secondaryColor: secondaryTextColor
    )
  }

  private var richBlockPalette: RichBlockPalette {
    .init(
      primary: textColor,
      secondary: secondaryTextColor,
      tertiary: .tertiaryLabelColor,
      link: linkColor
    )
  }

  private var richTextStyleKey: String {
    "minimal-default"
  }

  private var embeddedReplyStyle: EmbeddedMessageView.EmbeddedMessageStyle {
    .colored
  }

  private var senderFont: NSFont {
    .systemFont(
      ofSize: 13,
      weight: .medium
    )
  }

  private var isTimeOverlay: Bool {
    false
  }

  private var timeContentAlignment: MessageTimeAndState.ContentAlignment {
    props.layout.hasName ? .left : .right
  }

  // State
  private var isMouseInside = false
  private var quickActionsMenu: NSMenu?

  private enum Metrics {
    static let hoverSideInset: CGFloat = MessageSizeCalculator.minimalHoverSideInset
    static let hoverCornerRadius: CGFloat = 10
  }

  // Add gesture recognizer property
  private var longPressGesture: NSPressGestureRecognizer?
  private var doubleClickGesture: NSClickGestureRecognizer?

  // MARK: Views

  private lazy var hoverBackgroundView: BasicView = {
    let view = BasicView()
    view.cornerRadius = Metrics.hoverCornerRadius
    view.backgroundColor = nil
    view.isHidden = true
    return view
  }()

  private lazy var bubbleView: BasicView = {
    let view = BasicView()
    view.cornerRadius = Theme.messageBubbleCornerRadius
    view.backgroundColor = bubbleBackgroundColor
    return view
  }()

  private var shineEffectView: ShineEffectView?

  /// Set once `avatarView` is built (only rows that show an inline avatar build it).
  private var avatarViewIfLoaded: UserAvatarView?

  private lazy var avatarView: UserAvatarView = {
    let view = UserAvatarView(userInfo: avatarUserInfo, size: Self.avatarSize, viaMark: fullMessage.viaPresentation?.mark)
    avatarViewIfLoaded = view
    return view
  }()

  /// Set once `nameLabel` is built (only rows that show a name build it).
  private var nameLabelIfLoaded: NSTextField?

  private lazy var nameLabel: NSTextField = {
    let label = MessageSenderNameLabel()
    nameLabelIfLoaded = label
    label.font = senderFont
    label.lineBreakMode = .byTruncatingTail
    let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleNameClick))
    clickGesture.delaysPrimaryMouseButtonEvents = false
    label.addGestureRecognizer(clickGesture)

    return label
  }()

  /// Set once `forwardHeaderLabel` is built. Rows without a forward header never build it.
  private var forwardHeaderLabelIfLoaded: NSTextField?

  private lazy var forwardHeaderLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = .preferredFont(forTextStyle: .callout)
    label.textColor = forwardHeaderTextColor
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.usesSingleLineMode = true
    let clickGesture = NSClickGestureRecognizer(
      target: self,
      action: #selector(handleForwardHeaderClick)
    )
    label.addGestureRecognizer(clickGesture)
    forwardHeaderLabelIfLoaded = label
    return label
  }()

  private lazy var contentView: NSView = NSView()

  private lazy var timeAndStateView: MessageTimeAndState = {
    let view = MessageTimeAndState(
      fullMessage: fullMessage,
      overlay: isTimeOverlay,
      contentAlignment: timeContentAlignment,
      // `updateHoverChrome` registers it once the label shows.
      showsToolTip: false
    )
    view.wantsLayer = true
    return view
  }()

  /// Set once `photoView` is built. Reads that must not build the photo view use this.
  private var photoViewIfLoaded: NewPhotoView?

  private lazy var photoView: NewPhotoView = {
    let view = NewPhotoView(fullMessage, scrollState: scrollState, roundsAllCorners: true)
    // Placed by frame (`layoutParts`); the view opts itself into constraints.
    view.translatesAutoresizingMaskIntoConstraints = true
    view.cornerRadiusReduction = 3
    photoViewIfLoaded = view
    return view
  }()

  /// An album's islands, in its photo's place (`props.album`). The photo view keeps the slot and
  /// stays hidden under it; `layoutParts` gives the grid the slot's frame.
  private var albumGridView: MessageAlbumGridView?

  private func syncAlbumGrid() {
    guard let album = props.album, props.layout.photo != nil, photoViewIfLoaded?.superview != nil else {
      albumGridView?.removeFromSuperview()
      albumGridView = nil
      photoViewIfLoaded?.isHidden = false
      return
    }
    photoView.isHidden = true
    let grid = albumGridView ?? {
      let grid = MessageAlbumGridView()
      grid.frame = photoView.frame
      contentView.addSubview(grid, positioned: .above, relativeTo: photoView)
      albumGridView = grid
      needsLayout = true
      return grid
    }()
    grid.configure(
      album: album,
      availableWidth: props.layout.albumAvailableWidth ?? props.layout.photo?.size.width ?? 0,
      style: .islands,
      scrollState: scrollState,
      isRightToLeft: userInterfaceLayoutDirection == .rightToLeft,
      roundsTop: false,
      roundsBottom: false
    )
  }

  /// An album's file rows, in its document's place (`props.album`).
  private var albumFilesView: MessageAlbumFilesView?

  /// The album file row under the mouse, for the menu's file actions.
  private var albumFileRowUnderMouse: DocumentView? {
    guard let albumFilesView, let window, albumFilesView.superview != nil else { return nil }
    let point = albumFilesView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return albumFilesView.row(at: point)
  }

  /// Set once `videoView` is built. Reads that must not build the video view use this.
  private var videoViewIfLoaded: NewVideoView?

  private lazy var videoView: NewVideoView = {
    let view = NewVideoView(fullMessage, scrollState: scrollState, roundsAllCorners: true)
    // Placed by frame (`layoutParts`); the view opts itself into constraints.
    view.translatesAutoresizingMaskIntoConstraints = true
    view.cornerRadiusReduction = 3
    videoViewIfLoaded = view
    return view
  }()

  private lazy var documentContainerView: NSView = NSView()

  private lazy var documentView: DocumentView? = {
    guard let documentInfo = fullMessage.documentInfo else { return nil }

    let view = DocumentView(
      documentInfo: documentInfo,
      fullMessage: self.fullMessage,
      white: false
    )
    return view
  }()

  private lazy var voiceMessageView: NSHostingView<VoiceMessageBubble>? = {
    guard hasVoiceInDocumentSlot else { return nil }

    let view = NSHostingView(rootView: VoiceMessageBubble(
      message: fullMessage.message,
      outgoing: false,
      maxWidth: Theme.voiceMessageViewWidth,
      mode: .minimal
    ))
    return view
  }()

  /// Attachments
  ///
  /// Will do tasks, Loom embeds, etc.
  private var attachmentsView: MessageAttachmentsView?
  private var messageActionRowsView: MessageActionRowsView?
  private var uploadProgressView: PhotoUploadProgressView?

  /// A sending photo's upload bar sits in the list's bottom inset under the newest message, so
  /// it never changes the row's height and the list doesn't move when it leaves.
  private func syncUploadProgressView(props: MessageViewProps) {
    guard fullMessage.showsPhotoUploadProgress, props.isLastMessage,
          let photoLocalId = fullMessage.photoInfo?.photo.id
    else {
      // Sent: the bar fills, then fades. Otherwise it only fades.
      uploadProgressView?.dismiss(filling: !fullMessage.showsPhotoUploadProgress)
      uploadProgressView = nil
      return
    }

    let view = uploadProgressView ?? PhotoUploadProgressView()
    if view.superview == nil {
      addSubview(view)
    }
    view.configure(photoLocalId: photoLocalId)
    uploadProgressView = view
    needsLayout = true
  }

  private func layoutUploadProgressView() {
    guard let uploadProgressView else { return }
    let bubble = bubbleView.convert(bubbleView.bounds, to: self)
    let size = PhotoUploadProgressView.size
    uploadProgressView.frame = CGRect(
      x: bubble.minX,
      y: isFlipped
        ? bubble.maxY + PhotoUploadProgressView.topSpacing
        : bubble.minY - PhotoUploadProgressView.topSpacing - size.height,
      width: size.width,
      height: size.height
    )
  }

  private func createAttachmentsView() -> MessageAttachmentsView? {
    let view = MessageAttachmentsView(
      attachments: fullMessage.attachments,
      message: message,
      usesOutgoingBubbleStyle: false,
      itemPlans: props.layout.attachmentItems
    )
    // Placed by frame (`layoutParts`); the stack opts itself into constraints.
    view.translatesAutoresizingMaskIntoConstraints = true
    return view
  }

  private var renderableMessageActionRows: [MessageActionRow] {
    BlockInlineActions.renderableRows(for: message, drawnInside: props.layout.richBlockContent?.claimedActionIDs ?? [])
  }

  private func loadingActionIdsForCurrentMessage() -> Set<String> {
    MessageActionInteractionState.shared.loadingActionIds(
      peerId: message.peerId,
      messageId: message.messageId,
      rev: message.rev
    )
  }

  private func syncMessageActionRowsView(message: FullMessage, props: MessageViewProps) {
    guard props.layout.hasActionsRows, !renderableMessageActionRows.isEmpty else {
      messageActionRowsView?.removeFromSuperview()
      messageActionRowsView = nil
      // Buttons drawn inside blocks still need loading, answers (toasts, alerts) and grants.
      if props.layout.richBlockContent?.claimedActionIDs.isEmpty == false {
        ensureMessageActionStateObservation()
        return
      }
      messageActionLoadingCancellable?.cancel()
      messageActionLoadingCancellable = nil
      messageActionAnsweredCancellable?.cancel()
      messageActionAnsweredCancellable = nil
      messageActionGrantsCancellable?.cancel()
      messageActionGrantsCancellable = nil
      return
    }

    ensureMessageActionStateObservation()

    let view = messageActionRowsView ?? MessageActionRowsView()
    if view.superview == nil {
      // Placed by frame (`layoutParts`); the view opts itself into constraints.
      view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(view)
      needsLayout = true
    }

    view.onActionTap = { [weak self] action in
      self?.handleMessageActionTap(action)
    }

    view.configure(
      rows: renderableMessageActionRows,
      loadingActionIds: loadingActionIdsForCurrentMessage(),
      outgoing: false,
      rowHeight: 24,
      messageFontSize: props.layout.fontSize,
      presentation: { [message = message.message] action in MessageActionPerformer.presentation(for: action, message: message) }
    )

    messageActionRowsView = view
  }

  private func ensureMessageActionStateObservation() {
    guard messageActionLoadingCancellable == nil || messageActionAnsweredCancellable == nil else { return }

    messageActionLoadingCancellable?.cancel()
    messageActionAnsweredCancellable?.cancel()

    messageActionLoadingCancellable = MessageActionInteractionState.shared.loadingPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.refreshMessageActionRowsView()
      }

    // Grants load once per bot; re-render so buttons the viewer cannot use
    // turn disabled with their reason.
    messageActionGrantsCancellable = AgentGrantStore.shared.$accessByBotUserID
      .map { [botUserID = message.fromId] in $0[botUserID] }
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        self?.refreshMessageActionRowsView()
      }

    messageActionAnsweredCancellable = MessageActionInteractionState.shared.answeredPublisher
      .receive(on: DispatchQueue.main)
      .sink { [weak self] event in
        guard let self else { return }
        guard event.key.peerId == message.peerId, event.key.messageId == message.messageId else { return }

        refreshMessageActionRowsView()

        if let toastText = event.toastText {
          ToastCenter.shared.showInfo(toastText)
        }
        if let alert = event.alert {
          MessageActionPerformer.presentAlert(alert, in: window)
        }
        if let openURL = event.openURL {
          MessageActionPerformer.openResponseURL(openURL, pressedAt: event.pressedAt, in: window)
        }
      }
  }

  private func refreshMessageActionRowsView() {
    richBlockContentView?.refreshInlineActionStates()
    guard let messageActionRowsView else { return }
    messageActionRowsView.configure(
      rows: renderableMessageActionRows,
      loadingActionIds: loadingActionIdsForCurrentMessage(),
      outgoing: false,
      rowHeight: 24,
      messageFontSize: props.layout.fontSize,
      presentation: { [message] action in MessageActionPerformer.presentation(for: action, message: message) }
    )
  }

  private func handleMessageActionTap(_ action: MessageAction) {
    let presentation = MessageActionPerformer.presentation(for: action, message: message)
    MessageGestureTrace.debug(
      "MinimalMessageView.handleMessageActionTap messageId=\(message.messageId) actionIdBytes=\(action.actionID.utf8.count) intent=\(presentation.intent) enabled=\(presentation.isEnabled)"
    )
    MessageActionPerformer.run(presentation, in: window) { [weak self] in
      guard let self else { return }
      if presentation.intent == .callback {
        invokeMessageCallbackAction(action)
      } else {
        MessageActionPerformer.performLocal(presentation.intent, compose: postCompose) { [weak self] peer in
          self?.openChat(peer: peer)
        }
      }
    }
  }

  /// Puts `text` in the composer of this message's chat, or of the thread it anchors.
  private func postCompose(_ text: String) {
    MessageComposeRequests.shared.post(text, from: message, isThreadAnchor: isAnchorMessage)
  }

  private func invokeMessageCallbackAction(_ action: MessageAction) {
    let actionId = action.actionID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !actionId.isEmpty else { return }

    let loadingKey = MessageActionInteractionState.LoadingKey(
      peerId: message.peerId,
      messageId: message.messageId,
      rev: message.rev,
      actionId: actionId
    )

    guard MessageActionInteractionState.shared.begin(key: loadingKey) else { return }
    refreshMessageActionRowsView()

    Task {
      do {
        let result = try await Api.realtime.send(
          .invokeMessageAction(
            peerId: message.peerId,
            messageId: message.messageId,
            actionId: actionId
          )
        )

        guard case let .invokeMessageAction(response) = result else {
          throw MessageActionInvokeError.invalidResponse
        }

        await MainActor.run {
          MessageActionInteractionState.shared.attachInteractionId(
            response.interactionID,
            for: loadingKey
          )
          refreshMessageActionRowsView()
        }
      } catch {
        await MainActor.run {
          MessageActionInteractionState.shared.fail(key: loadingKey)
          refreshMessageActionRowsView()
          ToastCenter.shared.showError("Action failed")
        }
      }
    }
  }

  private func syncForwardHeaderView(for props: MessageViewProps) {
    guard props.layout.hasForwardHeader else {
      if let forwardHeaderLabelIfLoaded, forwardHeaderLabelIfLoaded.superview != nil {
        forwardHeaderLabelIfLoaded.removeFromSuperview()
      }
      return
    }

    forwardHeaderLabel.textColor = .controlAccentColor
    forwardHeaderLabel.stringValue = forwardHeaderText

    if forwardHeaderLabel.superview == nil {
      contentView.addSubview(forwardHeaderLabel)
      needsLayout = true
    }
  }

  private func syncDocumentSlotView() {
    guard hasDocument else {
      documentContainerView.subviews.forEach { $0.removeFromSuperview() }
      return
    }

    let desiredView: NSView?
    if hasVoiceInDocumentSlot {
      voiceMessageView?.rootView = VoiceMessageBubble(
        message: fullMessage.message,
        outgoing: false,
        maxWidth: Theme.voiceMessageViewWidth,
        mode: .minimal
      )
      desiredView = voiceMessageView
    } else if let album = props.album, album.hasFiles {
      let files = albumFilesView ?? {
        let view = MessageAlbumFilesView()
        albumFilesView = view
        return view
      }()
      files.configure(items: album.fileItems, white: false)
      desiredView = files
    } else {
      if let documentInfo = fullMessage.documentInfo {
        documentView?.update(with: documentInfo, fullMessage: fullMessage)
      }
      desiredView = documentView
    }

    for subview in documentContainerView.subviews where subview !== desiredView {
      subview.removeFromSuperview()
    }

    guard let desiredView else { return }

    if desiredView.superview !== documentContainerView {
      desiredView.removeFromSuperview()
      // Fills the slot, whose frame `layoutParts` sets.
      desiredView.translatesAutoresizingMaskIntoConstraints = true
      desiredView.autoresizingMask = [.width, .height]
      desiredView.frame = documentContainerView.bounds
      documentContainerView.addSubview(desiredView)
    }
  }

  /// Reply
  /// Set once `replyView` is built. Reads that must not build the reply preview use this.
  private var replyViewIfLoaded: EmbeddedMessageView?

  private lazy var replyView: EmbeddedMessageView = {
    let view = EmbeddedMessageView(style: embeddedReplyStyle)
    replyViewIfLoaded = view
    view.usesFrameLayout()
    view.setRelatedMessage(fullMessage.message)
    if let embeddedMessage = fullMessage.repliedToMessage {
      view.update(with: embeddedMessage, kind: .replyInMessage)
    }
    return view
  }()

  /// Set once `replyThreadSummaryView` is built. Only rows whose layout has a reply thread
  /// summary build it; reads that must not build it use this.
  private var replyThreadSummaryViewIfLoaded: ReplyThreadSummaryView?

  private lazy var replyThreadSummaryView: ReplyThreadSummaryView = {
    let view = ReplyThreadSummaryView(style: embeddedReplyStyle)
    // Placed by frame (`layoutParts`); the view opts itself into constraints.
    view.translatesAutoresizingMaskIntoConstraints = true
    view.isHidden = true
    view.onTap = { [weak self] flags in
      if let self {
        MessageGestureTrace.debug(
          "MinimalMessageView.replyThreadSummaryTap messageId=\(self.message.messageId) modifiers=\(flags.rawValue)"
        )
      }
      self?.openReplyThreadFlow(
        source: .threadSummary,
        action: ReplyThreadOpenAction(
          modifierFlags: flags,
          opensInSidePane: AppSettings.shared.openReplyThreadsInSidePane
        )
      )
    }
    view.menuProvider = { [weak self] in
      self?.makeReplyThreadSummaryMenu()
    }
    replyThreadSummaryViewIfLoaded = view
    return view
  }()

  private func shouldShowReplyThreadSummary(for props: MessageViewProps) -> Bool {
    props.layout.hasReplyThreadSummary
      && props.interactionMode != .threadAnchor
      && message.hasReplyThreadSummary
  }

  private func updateReplyThreadSummaryView(for props: MessageViewProps) {
    guard shouldShowReplyThreadSummary(for: props), let summary = message.threadCard else {
      replyThreadSummaryViewIfLoaded?.setStyle(embeddedReplyStyle)
      replyThreadSummaryViewIfLoaded?.clear()
      return
    }

    let replyThreadSummaryView = installReplyThreadSummaryViewIfNeeded()
    replyThreadSummaryView.setStyle(embeddedReplyStyle)
    replyThreadSummaryView.update(
      kind: summary.kind,
      messageCount: summary.messageCount,
      recentAuthors: recentReplyThreadAuthors(),
      hasUnread: summary.hasUnread,
      title: props.replyThreadTitle
    )
    replyThreadSummaryView.isHidden = false
  }

  /// Setup adds the summary for rows whose layout has one. This covers a row that starts
  /// showing one later without being rebuilt.
  @discardableResult
  private func installReplyThreadSummaryViewIfNeeded() -> ReplyThreadSummaryView {
    let view = replyThreadSummaryView
    guard view.superview == nil else { return view }
    contentView.addSubview(view)
    needsLayout = true
    return view
  }

  private func recentReplyThreadAuthors() -> [UserInfo] {
    let userIds = message.replyThreadRecentReplierUserIds
    let users = ObjectCache.shared.get(userIds.map(ObjectID.user))
    return userIds.map { userId in
      users.user(userId) ?? UserInfo(
        user: User(id: userId, email: nil, firstName: nil)
      )
    }
  }

  private var useTextKit2: Bool = true

  private var prevDelegate: NSTextViewportLayoutControllerDelegate?

  /// Whether the NSTextView exists. Messages drawn by Core Text, and messages without text,
  /// never create one.
  private var isNativeTextViewLoaded = false

  private var textView: NSTextView {
    isNativeTextViewLoaded = true
    return nativeTextView
  }

  /// Plain text drawn by Inline's Core Text renderer instead of NSTextView, behind the
  /// "Core Text Message Text" experiment. Rich messages and code blocks stay on NSTextView.
  private var coreTextView: CoreTextMessageView?
  private var usesCoreText = false

  /// The view that shows this message's text, created on demand.
  private var textHostView: NSView {
    usesCoreText ? loadCoreTextView() : textView
  }

  /// The text view when it is in the view hierarchy; never creates one.
  private var attachedTextHost: NSView? {
    if usesCoreText {
      return coreTextView?.superview != nil ? coreTextView : nil
    }
    return isNativeTextViewLoaded && textView.superview != nil ? textView : nil
  }

  private var textSurface: (any MessageTextSurface)? {
    if usesCoreText { return coreTextView }
    return isNativeTextViewLoaded ? textView as? MessageTextView : nil
  }

  private func loadCoreTextView() -> CoreTextMessageView {
    if let coreTextView { return coreTextView }
    let view = CoreTextMessageView(frame: .zero)
    coreTextView = view
    return view
  }

  private func wantsCoreTextRenderer() -> Bool {
    // Rich messages use it too, as the host their blocks are placed in.
    guard CoreTextMessageText.isEnabled, hasText else { return false }
    return props.layout.richBlockContent != nil
      || CoreTextMessageText.supports(entities: fullMessage.translationEntities ?? fullMessage.message.entities)
  }

  /// Moves the message's text between NSTextView and the Core Text view.
  private func applyTextRenderer(coreText: Bool) {
    guard coreText != usesCoreText else { return }
    if let host = attachedTextHost {
      textSurface?.onEntityClick = nil
      textSurface?.onTextLongPress = nil
      host.removeFromSuperview()
    }
    usesCoreText = coreText
    needsLayout = true
    setupBoundsChangeObserver()
  }

  private lazy var nativeTextView: NSTextView = {
    if useTextKit2 {
      let textView = MessageTextView(usingTextLayoutManager: true)
      textView.isEditable = false
      textView.isSelectable = true
      textView.backgroundColor = .clear
      textView.drawsBackground = false
      // Clips to bounds = false fucks up performance so badly. what!?
      // textView.clipsToBounds = true
      textView.textContainerInset = MessageTextConfiguration.containerInset
      textView.font = ChatTypography.current.font(sized: props.layout.fontSize)
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

      if MessageTextConfiguration.useTextKit2ViewportWorkarounds {
        // Avoid our custom TextKit 2 viewport delegate on macOS 27; crash reports show
        // AppKit throwing while configuring viewport surfaces during NSTableView row install.
        prevDelegate = textView.textLayoutManager?.textViewportLayoutController.delegate
        textView.textLayoutManager?.textViewportLayoutController.delegate = self
      }

      // In NSTextView you need to customize link colors here otherwise the attributed string for links
      // does not have any effect.
      textView.linkTextAttributes = [
        .foregroundColor: linkColor,
        // Intentional underline is carried by each attributed run.
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
      return textView
    }
  }()

  private var richBlockContentView: RichBlockContentView?

  private var reactionsView: MessageReactionsView?
  // The second mouse-down event is a reliable double-click boundary even when
  // AppKit admits NSClickGestureRecognizer but never calls its target action.
  private var handledDoubleClickEventNumber: Int?
  private var handledEntityClickEventNumber: Int?

  // MARK: - Link Detection

  /// Stores detected links for tap handling
  private var detectedLinks: [(range: NSRange, url: URL)] = []

  /// Handles link clicks by opening the URL in the default browser
  private func handleLinkClick(at characterIndex: Int) {
    guard let url = linkURL(at: characterIndex, in: displayedText) else {
      MessageGestureTrace.debug(
        "MinimalMessageView.handleLinkClick messageId=\(message.messageId) char=\(characterIndex) result=noURL"
      )
      return
    }
    MessageGestureTrace.debug("MinimalMessageView.handleLinkClick messageId=\(message.messageId) char=\(characterIndex) url=\(MessageGestureTrace.url(url))")
    openTextURL(url)
  }

  private func linkURLForContextMenu(at characterIndex: Int) -> URL? {
    linkURL(at: characterIndex, in: displayedText)
  }

  private var displayedText: NSAttributedString {
    textSurface?.surfaceText ?? NSAttributedString()
  }

  private func linkURL(at characterIndex: Int, in attributedString: NSAttributedString) -> URL? {
    guard characterIndex != NSNotFound else { return nil }

    if let match = detectedLinks.first(where: { NSLocationInRange(characterIndex, $0.range) }) {
      return match.url
    }

    guard characterIndex < attributedString.length else { return nil }

    if let value = attributedString.attribute(.link, at: characterIndex, effectiveRange: nil) {
      if let url = value as? URL {
        return url
      }
      if let urlString = value as? String, let url = URL(string: urlString) {
        return url
      }
    }

    return nil
  }

  private func openTextURL(_ url: URL) {
    if let deepLink = InlineDeepLink(url: url) ?? InlineDeepLink(universalLink: url) {
      if case let .user(userId) = deepLink {
        MessageGestureTrace.debug("MinimalMessageView.openTextURL messageId=\(message.messageId) action=openInlineUser userId=\(userId)")
      }
      Task { @MainActor in
        await openInlineDeepLink(deepLink)
      }
      return
    }
    if InlineDeepLink.isSupportedScheme(url.scheme) {
      if url.host?.lowercased() == "user" {
        MessageGestureTrace.debug("MinimalMessageView.openTextURL messageId=\(message.messageId) action=unresolvedInlineUser")
      }
      return
    }
    if let fileLink = LocalFileLink(url: url) {
      MessageGestureTrace.debug("MinimalMessageView.openTextURL messageId=\(message.messageId) action=openLocalFile")
      let sender = fullMessage.from
      Task { @MainActor in
        await LocalFileLinkOpener.open(fileLink, from: sender)
      }
      return
    }
    guard url.scheme != nil else { return }

    log.debug("Link clicked: \(MessageGestureTrace.url(url))")
    MessageGestureTrace.debug("MinimalMessageView.openTextURL messageId=\(message.messageId) action=openExternal url=\(MessageGestureTrace.url(url))")
    NSWorkspace.shared.open(url)
  }

  @MainActor private func openInlineDeepLink(_ deepLink: InlineDeepLink) async {
    switch deepLink {
    case let .user(id):
      openChat(peer: .user(id: id))
    case let .chat(id):
      if let dependencies {
        await dependencies.requestOpenChat(chatId: id)
      } else if let url = deepLink.url() {
        NSWorkspace.shared.open(url)
      }
    case let .message(chatId, messageId):
      if let dependencies {
        await dependencies.requestOpenChat(chatId: chatId, targetMessageId: messageId)
      } else if let url = deepLink.url() {
        NSWorkspace.shared.open(url)
      }
    case .publicSpace, .spaceInvite:
      if let url = deepLink.url() {
        NSWorkspace.shared.open(url)
      }
    }
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
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Lifecycle

  override func layout() {
    super.layout()
    layoutParts()
    layoutAcknowledgement()
    layoutViaFooter()
    layoutUploadProgressView()
  }

  private func layoutViaFooter() {
    guard showsViaFooter, timeHiddenForStream == nil, let via = fullMessage.viaPresentation else {
      viaFooterLabel?.isHidden = true
      return
    }
    let label = viaFooterLabel ?? makeViaFooterLabel()
    if label.stringValue != via.label {
      label.stringValue = via.label
    }
    label.toolTip = via.detail(senderName: fullMessage.senderInfo?.user.shortDisplayName)
    label.isHidden = false
    let content = contentView.convert(contentView.bounds, to: self)
    let height: CGFloat = 16
    // The footer row runs from the content's leading edge to the row's trailing safe edge,
    // or to a standalone Ack pill on the same row, not just the content's width: a short
    // message such as "ok" would otherwise cut "Sent via Claude Code" to "Sent via…".
    var trailing = bounds.maxX - MessageSizeCalculator.minimalHoverSideInset
      - MessageSizeCalculator.minimalHoverContentInset
    if let acknowledgementView, !acknowledgementView.isHidden, reactionsView?.isHidden != false {
      trailing = min(trailing, acknowledgementView.frame.minX - 8)
    }
    let width = min(ceil(label.intrinsicContentSize.width), max(0, trailing - content.minX))
    // Bottom row of the wrapper, the same row a standalone Ack pill uses.
    let top = props.layout.wrapper.spacing.top + props.layout.wrapper.size.height - height
    let y = isFlipped ? top : bounds.height - top - height
    label.frame = CGRect(x: content.minX, y: y, width: width, height: height)
  }

  private func makeViaFooterLabel() -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 11)
    label.textColor = .tertiaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = true
    addSubview(label)
    viaFooterLabel = label
    return label
  }

  private func configureAcknowledgement(animated: Bool) {
    let message = isAnchorMessage ? fullMessage.withoutAcknowledgements : fullMessage
    let view: MessageAcknowledgementView
    if let acknowledgementView {
      view = acknowledgementView
    } else {
      guard !message.acknowledgementActors.isEmpty else { return }
      view = MessageAcknowledgementView()
      view.onToggle = { [weak self] in
        self?.acknowledgeMessage()
      }
      // Bottom-most, where setup used to add it before every other subview.
      addSubview(view, positioned: .below, relativeTo: subviews.first)
      acknowledgementView = view
    }
    view.configure(
      message,
      fallbackRTL: props.isRtl || userInterfaceLayoutDirection == .rightToLeft,
      action: currentAcknowledgementAction(),
      animated: animated
    )
  }

  private func layoutAcknowledgement() {
    guard hasAcknowledgement, let acknowledgementView else {
      if let acknowledgementView, !acknowledgementView.isAnimatingRemoval {
        acknowledgementView.isHidden = true
      }
      return
    }
    acknowledgementView.isHidden = false
    let content = contentView.convert(contentView.bounds, to: self)
    let width = min(fullMessage.acknowledgementPillWidth, max(fullMessage.acknowledgementMinimumPillWidth, content.width))
    // Minimal rows already span the table width. Project Ack to that row's
    // existing safe edge without widening or remeasuring message content.
    let trailingInset = MessageSizeCalculator.minimalHoverSideInset
      + MessageSizeCalculator.minimalHoverContentInset
    let x = max(content.minX, bounds.maxX - trailingInset - width)
    let y: CGFloat
    if let reactionsView, !reactionsView.isHidden {
      let reactions = reactionsView.convert(reactionsView.bounds, to: self)
      y = isFlipped ? reactions.maxY - 6 - 16 : reactions.minY + 6
    } else {
      let top = props.layout.wrapper.spacing.top + props.layout.wrapper.size.height - 16
      y = isFlipped ? top : bounds.height - top - 16
    }
    acknowledgementView.frame = CGRect(x: x, y: y, width: width, height: 16)
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()

    if superview == nil {
      quickActionsMenu?.cancelTracking()
      updateHoverState(false)
    }

    setupBoundsChangeObserver()
    setupScrollStateObserver()
  }

  override func mouseDown(with event: NSEvent) {
    MessageGestureTrace.trace("MinimalMessageView.mouseDown messageId=\(message.messageId) \(MessageGestureTrace.eventDescription(event))")
    super.mouseDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    MessageGestureTrace.trace("MinimalMessageView.mouseUp messageId=\(message.messageId) \(MessageGestureTrace.eventDescription(event))")
    super.mouseUp(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    MessageGestureTrace.trace("MinimalMessageView.mouseDragged messageId=\(message.messageId) \(MessageGestureTrace.eventDescription(event))")
    super.mouseDragged(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    MessageGestureTrace.trace("MinimalMessageView.rightMouseDown messageId=\(message.messageId) \(MessageGestureTrace.eventDescription(event))")
    super.rightMouseDown(with: event)
  }

  override func rightMouseUp(with event: NSEvent) {
    MessageGestureTrace.trace("MinimalMessageView.rightMouseUp messageId=\(message.messageId) \(MessageGestureTrace.eventDescription(event))")
    super.rightMouseUp(with: event)
  }

  override func rightMouseDragged(with event: NSEvent) {
    MessageGestureTrace.trace("MinimalMessageView.rightMouseDragged messageId=\(message.messageId) \(MessageGestureTrace.eventDescription(event))")
    super.rightMouseDragged(with: event)
  }

  override func otherMouseDragged(with event: NSEvent) {
    MessageGestureTrace.trace("MinimalMessageView.otherMouseDragged messageId=\(message.messageId) \(MessageGestureTrace.eventDescription(event))")
    super.otherMouseDragged(with: event)
  }

  override func otherMouseDown(with event: NSEvent) {
    MessageGestureTrace.trace("MinimalMessageView.otherMouseDown messageId=\(message.messageId) \(MessageGestureTrace.eventDescription(event))")
    super.otherMouseDown(with: event)
  }

  override func otherMouseUp(with event: NSEvent) {
    MessageGestureTrace.trace("MinimalMessageView.otherMouseUp messageId=\(message.messageId) \(MessageGestureTrace.eventDescription(event))")
    super.otherMouseUp(with: event)
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let localPoint = convert(point, from: superview)
    if !isHidden, bounds.contains(localPoint), let result = interactiveHitTestResult(localPoint) {
      MessageGestureTrace.trace(
        "MinimalMessageView.hitTest messageId=\(message.messageId) point=\(MessageGestureTrace.point(point)) interactive=\(result.name) view=\(type(of: result.view))"
      )
      return result.view
    }

    let hit = super.hitTest(point)
    MessageGestureTrace.trace(
      "MinimalMessageView.hitTest messageId=\(message.messageId) point=\(MessageGestureTrace.point(point)) superHit=\(String(describing: hit.map { type(of: $0) }))"
    )
    return hit
  }

  // MARK: - Setup

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let observer = notificationObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    if let observer = boundsChangeObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    translationStateCancellable?.cancel()
    messageActionLoadingCancellable?.cancel()
    messageActionAnsweredCancellable?.cancel()
  }

  private func setupView() {
    configureAcknowledgement(animated: false)
    // For performance of animations
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
    layer?.drawsAsynchronously = true

    addSubview(hoverBackgroundView)
    addSubview(bubbleView)

    addSubview(contentView)
    syncSenderViews()

    syncForwardHeaderView(for: props)

    if hasReply {
      contentView.addSubview(replyView)
    }

    if props.layout.hasReplyThreadSummary {
      contentView.addSubview(replyThreadSummaryView)
    }

    if hasPhoto {
      contentView.addSubview(photoView)
    }

    if hasVideo {
      contentView.addSubview(videoView)
    }

    if hasDocument {
      contentView.addSubview(documentContainerView)
      syncDocumentSlotView()
    }

    // An album's grid sits over the photo slot: built with the view (as in the bubble view).
    syncAlbumGrid()

    syncTextViewForCurrentProps()

    syncMessageActionRowsView(message: fullMessage, props: props)
    syncUploadProgressView(props: props)

    if hasReactions {
      setupReactions(animate: false)
    }

    if hasAttachments {
      attachmentsView = createAttachmentsView()
      contentView.addSubview(attachmentsView!)
    }

    updateReplyThreadSummaryView(for: props)

    addSubview(timeAndStateView)
    updateHoverChrome()

    setupMessageText()
    setupContextMenu()
    setupGestureRecognizers()

    // Setup translation state observation
    setupTranslationStateObservation()
    layoutContentParts()
  }

  /// The sender's name and color. A reused view can move to another sender's message.
  private func configureNameLabel() {
    let sender = outgoing ? (dependencies?.rootData?.currentUserInfo?.user ?? from) : from
    let senderName = sender.shortDisplayName
    // Previous outgoing label behavior, kept as reference for quick revert.
    // nameLabel.stringValue = outgoing ? "You" : senderName
    guard nameLabel.stringValue != senderName || configuredNameSenderId != sender.id else { return }
    configuredNameSenderId = sender.id
    nameLabel.stringValue = senderName
    nameLabel.textColor = NSColor(
      InitialsCircle.ColorPalette
        .color(for: UserAvatar.getNameForInitials(user: sender))
    )
  }

  private var configuredNameSenderId: Int64?

  private func setupTranslationStateObservation() {
    guard AppSettings.shared.translationUIEnabled else {
      translationStateCancellable?.cancel()
      translationStateCancellable = nil
      updateShineEffect(isTranslating: false)
      return
    }

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
    guard let messageTextView = textSurface else {
      MessageGestureTrace.debug("MinimalMessageView.setupEntityClickHandling messageId=\(message.messageId) result=noMessageTextView")
      return
    }
    // Keep entity ownership in the message view, but start from NSTextView's
    // mouseDown because recognizers attached to text views can be swallowed.
    messageTextView.onEntityClick = { [weak self] location, event in
      self?.handleEntityClick(at: location, event: event) ?? false
    }
    messageTextView.onTextLongPress = { [weak self] location, event in
      self?.handleTextLongPress(at: location, event: event)
    }
    MessageGestureTrace.debug("MinimalMessageView.setupEntityClickHandling messageId=\(message.messageId) mode=mouseDownCallback")
  }

  private func syncTextViewForCurrentProps() {
    applyTextRenderer(coreText: wantsCoreTextRenderer())
    if usesCoreText {
      syncCoreTextViewForCurrentProps()
      return
    }
    if hasText {
      if textView.superview == nil {
        addTextHostToContent(textView)
        needsLayout = true
        MessageGestureTrace.debug("MinimalMessageView.syncTextView messageId=\(message.messageId) action=attachTextView")
      }
      if let messageTextView = textView as? MessageTextView {
        if messageTextView.onEntityClick == nil {
          setupEntityClickHandling()
        }
      } else {
        setupEntityClickHandling()
      }
      return
    }

    guard isNativeTextViewLoaded, textView.superview != nil else { return }
    MessageGestureTrace.debug("MinimalMessageView.syncTextView messageId=\(message.messageId) action=detachTextView")
    (textView as? MessageTextView)?.onEntityClick = nil
    (textView as? MessageTextView)?.onTextLongPress = nil
    textView.removeFromSuperview()
    detectedLinks = []
  }

  /// Text joins the content view below the reaction chips (a reused view can gain text after its reactions).
  private func addTextHostToContent(_ view: NSView) {
    if let reactionsView, reactionsView.superview === contentView {
      contentView.addSubview(view, positioned: .below, relativeTo: reactionsView)
    } else {
      contentView.addSubview(view)
    }
  }

  private func syncCoreTextViewForCurrentProps() {
    let view = loadCoreTextView()
    guard hasText else {
      guard view.superview != nil else { return }
      view.onEntityClick = nil
      view.onTextLongPress = nil
      view.removeFromSuperview()
      detectedLinks = []
      return
    }
    if view.superview == nil {
      addTextHostToContent(view)
      needsLayout = true
    }
    if view.onEntityClick == nil {
      setupEntityClickHandling()
    }
    if view.onContextMenu == nil {
      view.onContextMenu = { [weak self, weak view] index, event in
        guard let self, let view else { return nil }
        return createMenu(
          context: .textView,
          nativeMenu: view.nativeTextMenu(at: index, event: event),
          linkURL: index.flatMap { self.linkURLForContextMenu(at: $0) }
        )
      }
    }
  }

  @discardableResult
  private func handleEntityClick(at location: NSPoint, event: NSEvent? = nil) -> Bool {
    if let event, handledEntityClickEventNumber == event.eventNumber {
      MessageGestureTrace.debug(
        "MinimalMessageView.handleEntityClick messageId=\(message.messageId) point=\(MessageGestureTrace.point(location)) result=alreadyHandled eventNumber=\(event.eventNumber)"
      )
      return true
    }

    guard let hit = textEntityHit(at: location) else {
      MessageGestureTrace.debug(
        "MinimalMessageView.handleEntityClick messageId=\(message.messageId) point=\(MessageGestureTrace.point(location)) result=noHit"
      )
      return false
    }
    let handled = handleTextEntityClick(hit, attributedString: displayedText)
    if handled, let event {
      handledEntityClickEventNumber = event.eventNumber
    }
    MessageGestureTrace.debug(
      "MinimalMessageView.handleEntityClick messageId=\(message.messageId) point=\(MessageGestureTrace.point(location)) hit=\(hit) handled=\(handled)"
    )
    return handled
  }

  @discardableResult
  private func handleTextEntityClick(
    _ hit: MessageTextEntityHit,
    attributedString: NSAttributedString
  ) -> Bool {
    switch hit {
    case let .codeBlock(codeRange):
      let codeText = (attributedString.string as NSString).substring(with: codeRange)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(codeText, forType: .string)
      ToastCenter.shared.showSuccess("Copied code")
      performProgressiveHaptic()
      MessageGestureTrace.debug(
        "MinimalMessageView.handleTextEntityClick messageId=\(message.messageId) action=copyCodeBlock range=\(MessageGestureTrace.range(codeRange))"
      )
      return true

    case let .inlineCode(inlineCodeRange):
      let inlineCodeText = (attributedString.string as NSString).substring(with: inlineCodeRange)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(inlineCodeText, forType: .string)
      ToastCenter.shared.showSuccess("Copied code")
      performProgressiveHaptic()
      MessageGestureTrace.debug(
        "MinimalMessageView.handleTextEntityClick messageId=\(message.messageId) action=copyInlineCode range=\(MessageGestureTrace.range(inlineCodeRange))"
      )
      return true

    case let .text(range):
      let characterIndex = range.location
      guard characterIndex != NSNotFound, characterIndex < attributedString.length else {
        MessageGestureTrace.debug(
          "MinimalMessageView.handleTextEntityClick messageId=\(message.messageId) action=none reason=badCharacterIndex range=\(MessageGestureTrace.range(range))"
        )
        return false
      }

      if let userId = attributedString.attribute(.mentionUserId, at: characterIndex, effectiveRange: nil) as? Int64 {
        if let agentId = attributedString.attribute(.mentionAgentId, at: characterIndex, effectiveRange: nil) as? Int64 {
          MessageGestureTrace.debug(
            "MinimalMessageView.handleTextEntityClick messageId=\(message.messageId) action=resolveAgent agentId=\(agentId) range=\(MessageGestureTrace.range(range))"
          )
          Task { @MainActor in
            guard !(await BotAgentMentionNavigator.open(
              agentId: agentId,
              botUserId: userId,
              peer: message.peerId
            )) else { return }
            openChat(peer: .user(id: userId))
          }
          return true
        }
        Task { @MainActor in
          openChat(peer: .user(id: userId))
        }
        MessageGestureTrace.debug(
          "MinimalMessageView.handleTextEntityClick messageId=\(message.messageId) action=openMention userId=\(userId) range=\(MessageGestureTrace.range(range))"
        )
        return true
      }

      if let groupId = attributedString.attribute(.mentionGroupId, at: characterIndex, effectiveRange: nil) as? Int64 {
        NotificationCenter.default.post(
          name: .userGroupMentionTapped,
          object: nil,
          userInfo: ["target": UserGroupMentionTarget(groupId: groupId, spaceId: messageSpaceId())]
        )
        MessageGestureTrace.debug(
          "MinimalMessageView.handleTextEntityClick messageId=\(message.messageId) action=openGroupMention groupId=\(groupId) range=\(MessageGestureTrace.range(range))"
        )
        return true
      }

      if let threadTarget = attributedString.attribute(.threadLink, at: characterIndex, effectiveRange: nil)
        as? ThreadLinkTarget
      {
        openThreadLink(threadTarget)
        MessageGestureTrace.debug(
          "MinimalMessageView.handleTextEntityClick messageId=\(message.messageId) action=openThreadLink range=\(MessageGestureTrace.range(range))"
        )
        return true
      }

      var commandRange = NSRange(location: 0, length: 0)
      if let command = attributedString.attribute(.botCommand, at: characterIndex, effectiveRange: &commandRange) as? String,
         commandRange.length > 0
      {
        let commandText = command.isEmpty
          ? (attributedString.string as NSString).substring(with: commandRange)
          : command
        sendBotCommand(commandText)
        MessageGestureTrace.debug(
          "MinimalMessageView.handleTextEntityClick messageId=\(message.messageId) action=sendBotCommand range=\(MessageGestureTrace.range(commandRange))"
        )
        return true
      }

      if let email = attributedString.attribute(.emailAddress, at: characterIndex, effectiveRange: nil) as? String {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(email, forType: .string)
        ToastCenter.shared.showSuccess("Copied email")
        performProgressiveHaptic()
        MessageGestureTrace.debug(
          "MinimalMessageView.handleTextEntityClick messageId=\(message.messageId) action=copyEmail range=\(MessageGestureTrace.range(range))"
        )
        return true
      }

      if let phoneNumber = attributedString
        .attribute(.phoneNumber, at: characterIndex, effectiveRange: nil) as? String
      {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(phoneNumber, forType: .string)
        ToastCenter.shared.showSuccess("Copied number")
        performProgressiveHaptic()
        MessageGestureTrace.debug(
          "MinimalMessageView.handleTextEntityClick messageId=\(message.messageId) action=copyPhone range=\(MessageGestureTrace.range(range))"
        )
        return true
      }

      guard let url = linkURL(at: characterIndex, in: attributedString) else {
        MessageGestureTrace.debug(
          "MinimalMessageView.handleTextEntityClick messageId=\(message.messageId) action=none reason=noURL range=\(MessageGestureTrace.range(range))"
        )
        return false
      }
      openTextURL(url)
      MessageGestureTrace.debug(
        "MinimalMessageView.handleTextEntityClick messageId=\(message.messageId) action=openURL range=\(MessageGestureTrace.range(range)) url=\(MessageGestureTrace.url(url))"
      )
      return true
    }
  }

  private func sendBotCommand(_ command: String) {
    Task {
      do {
        try await Api.realtime.send(.sendMessage(
          text: command,
          peerId: message.peerId,
          chatId: message.chatId,
          replyToMsgId: nil,
          isSticker: nil,
          entities: botCommandEntities(for: command)
        ))
      } catch {
        ToastCenter.shared.showError("Failed to send command")
      }
    }
  }

  private func botCommandEntities(for command: String) -> MessageEntities {
    var entity = MessageEntity()
    entity.type = .botCommand
    entity.offset = 0
    entity.length = Int64((command as NSString).length)

    var entities = MessageEntities()
    entities.entities = [entity]
    return entities
  }

  private func textEntityHit(at location: NSPoint) -> MessageTextEntityHit? {
    guard let messageTextView = textSurface else { return nil }
    let hit = messageTextView.entityHit(
      at: location,
      extraTextRanges: detectedLinks.map(\.range)
    )
    MessageGestureTrace.trace(
      "MinimalMessageView.textEntityHit messageId=\(message.messageId) point=\(MessageGestureTrace.point(location)) hit=\(String(describing: hit))"
    )
    return hit
  }

  private func handleEntityClick(from event: NSEvent, source: String) -> Bool {
    guard event.type == .leftMouseDown, event.clickCount == 1 else { return false }
    if handledEntityClickEventNumber == event.eventNumber {
      MessageGestureTrace.debug(
        "MinimalMessageView.handleEntityClickFromEvent messageId=\(message.messageId) source=\(source) result=alreadyHandled eventNumber=\(event.eventNumber)"
      )
      return true
    }

    guard let textView = attachedTextHost, !textView.isHidden else { return false }

    let locationInSelf = convert(event.locationInWindow, from: nil)
    let locationInText = textView.convert(locationInSelf, from: self)
    guard textView.bounds.contains(locationInText) else { return false }

    let handled = handleEntityClick(at: locationInText, event: event)
    MessageGestureTrace.debug(
      "MinimalMessageView.handleEntityClickFromEvent messageId=\(message.messageId) source=\(source) point=\(MessageGestureTrace.point(locationInText)) handled=\(handled)"
    )
    return handled
  }

  private func isTextEntityPoint(_ locationInSelf: NSPoint) -> Bool {
    if let richBlockContentView, richBlockContentView.superview != nil, !richBlockContentView.isHidden,
       let hit = richBlockContentView.interactiveTextHitTest(
         richBlockContentView.convert(locationInSelf, from: self)
       ) as? (any MessageTextSurface) {
      return hit.entityHit(at: hit.convert(locationInSelf, from: self), extraTextRanges: []) != nil
    }
    guard let textView = attachedTextHost, !textView.isHidden else { return false }

    let locationInText = textView.convert(locationInSelf, from: self)
    guard textView.bounds.contains(locationInText) else { return false }

    return textEntityHit(at: locationInText) != nil
  }

  private func handleTextLongPress(at location: NSPoint, event: NSEvent) {
    let locationInSelf = textHostView.convert(location, to: self)
    MessageGestureTrace.debug(
      "MinimalMessageView.handleTextLongPress messageId=\(message.messageId) eventNumber=\(event.eventNumber) point=\(MessageGestureTrace.point(locationInSelf))"
    )

    if let result = interactiveHitTestResult(locationInSelf) {
      guard let text = result.view as? any MessageTextSurface, text.onTextLongPress != nil else {
        MessageGestureTrace.debug(
          "MinimalMessageView.handleTextLongPress messageId=\(message.messageId) blocked=interactive target=\(result.name)"
        )
        return
      }
    }

    if isTextEntityPoint(locationInSelf) {
      MessageGestureTrace.debug("MinimalMessageView.handleTextLongPress messageId=\(message.messageId) blocked=textEntity")
      return
    }

    performConfiguredHoldAction(at: locationInSelf, source: "textHold")
  }

  private func openThreadLink(_ target: ThreadLinkTarget) {
    if let peer = target.directPeer {
      openChat(peer: peer)
      performProgressiveHaptic()
      return
    }

    let database = dependencies?.database ?? AppDatabase.shared
    let currentUserId = dependencies?.auth.getCurrentUserId() ?? Auth.shared.getCurrentUserId()
    let realtimeV2 = dependencies?.realtimeV2 ?? Api.realtime
    Task { @MainActor in
      do {
        guard let peer = try await ThreadLinkResolver.resolveOrCreate(
          target,
          currentUserId: currentUserId,
          database: database,
          realtimeV2: realtimeV2
        ) else {
          ToastCenter.shared.showError("Thread not found")
          return
        }

        openChat(peer: peer)
        performProgressiveHaptic()
      } catch ThreadLinkResolver.Error.missingCurrentUser {
        ToastCenter.shared.showError("You're signed out. Please log in again.")
      } catch {
        ToastCenter.shared.showError("Failed to open thread")
        log.error("Failed to resolve thread link", error: error)
      }
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
        shineView.autoresizingMask = [.width, .height]
        bubbleView.addSubview(shineView)

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

  private func setupReactions(animate: Bool) {
    if let oldView = reactionsView {
      oldView.removeFromSuperview()
    }

    // View
    let view = MessageReactionsView()
    view.update(
      fullMessage: fullMessage,
      groups: fullMessage.groupedReactions,
      layoutItems: props.layout.reactionItems,
      forceIncomingStyle: true,
      transparentOutgoingStyle: false,
      neutralStyle: true,
      animate: animate
    )
    reactionsView = view

    // debug
//    let view = NSView()
//    view.translatesAutoresizingMaskIntoConstraints = false
//    view.wantsLayer = true
//    view.layer?.backgroundColor = NSColor.red.cgColor
//    reactionsView = view

    if hasText, let textView = attachedTextHost {
      if reactionsOutsideBubble {
        addSubview(reactionsView!)
      } else {
        // Keep reaction chips above the (transparent) NSTextView for reliable hit-testing.
        // When the textView overlaps the reactions area (even slightly due to layout rounding),
        // placing reactions "below" makes them appear visible but prevents clicks from reaching them.
        contentView.addSubview(reactionsView!, positioned: .above, relativeTo: textView)
      }
    } else {
      if reactionsOutsideBubble {
        addSubview(reactionsView!)
      } else {
        contentView.addSubview(reactionsView!)
      }
    }

    needsLayout = true
  }

  private func updateReactionsSizes() {
    reactionsView?.update(
      fullMessage: fullMessage,
      groups: fullMessage.groupedReactions,
      layoutItems: props.layout.reactionItems,
      forceIncomingStyle: true,
      transparentOutgoingStyle: false,
      neutralStyle: true,
      animate: false
    )
  }

  private func updateReactions(prev: FullMessage, next: FullMessage, props: MessageViewProps) {
    // A reused row showing another message takes its reactions as they are; only the same message animates.
    let animates = prev.id == next.id
    if let reactionsView, next.reactions.count == 0 {
      if animates {
        log.trace("Removing reactions view")
        reactionsView.removeFromSuperview()
        self.reactionsView = nil
      } else {
        // Another message without reactions: the view stays, hidden, for the next message with reactions, whose
        // emojis take its chips.
        reactionsView.isHidden = true
      }
      return
    }
    reactionsView?.isHidden = false

    let shouldPlaceOutside = props.layout.reactionsOutsideBubble
    if let reactionsView, shouldPlaceOutside != (reactionsView.superview === self) {
      log.trace("Rebuilding reactions view for placement change")
      setupReactions(animate: false)
      // Another message's reactions are placed by the layout pass before display; no forced pass.
      if animates { layoutSubtreeIfNeeded() }
      return
    }

    if reactionsView == nil, next.reactions.count > 0 {
      log.trace("Adding reactions view \(props.layout.reactions)")
      // Added
      setupReactions(animate: animates)
      if animates { layoutSubtreeIfNeeded() }
    } else {
      log.trace("Updating reactions view")
      reactionsView?.update(
        fullMessage: next,
        groups: next.groupedReactions,
        layoutItems: props.layout.reactionItems,
        forceIncomingStyle: true,
        transparentOutgoingStyle: false,
        neutralStyle: true,
        animate: animates
      )
    }
  }

  private func setupGestureRecognizers() {
    // Add long press gesture recognizer
    longPressGesture = NSPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
    longPressGesture?.minimumPressDuration = 0.5
    longPressGesture?.allowableMovement = 10
    longPressGesture?.buttonMask = 1
    longPressGesture?.delaysPrimaryMouseButtonEvents = false
    longPressGesture?.delegate = self
    if let gesture = longPressGesture {
      addGestureRecognizer(gesture)
    }
    MessageGestureTrace.debug("MinimalMessageView.setupGestureRecognizers messageId=\(message.messageId) added=longPress")

    // Add double click gesture recognizer
    doubleClickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
    doubleClickGesture?.numberOfClicksRequired = 2
    doubleClickGesture?.buttonMask = 1
    doubleClickGesture?.delaysPrimaryMouseButtonEvents = false
    doubleClickGesture?.delegate = self
    if let gesture = doubleClickGesture {
      addGestureRecognizer(gesture)
    }
    MessageGestureTrace.debug("MinimalMessageView.setupGestureRecognizers messageId=\(message.messageId) added=doubleClick")

  }

  /// The inline avatar and the sender name follow the plan and the sender: a reused view adds, fills or removes them
  /// (both sit below the content view, as setup used to add them).
  private func syncSenderViews() {
    if showsInlineAvatar {
      if avatarViewIfLoaded == nil {
        avatarView.onClick = { [weak self] in
          if let self {
            MessageGestureTrace.debug("MinimalMessageView.avatarClick messageId=\(self.message.messageId)")
          }
          self?.handleAvatarClick()
        }
      } else {
        avatarView.update(userInfo: avatarUserInfo, viaMark: fullMessage.viaPresentation?.mark)
      }
      if avatarView.superview !== self {
        addSubview(avatarView, positioned: .below, relativeTo: contentView)
        needsLayout = true
      }
    } else if let avatarViewIfLoaded, avatarViewIfLoaded.superview != nil {
      avatarViewIfLoaded.removeFromSuperview()
    }

    if showsName {
      configureNameLabel()
      if nameLabel.superview !== self {
        addSubview(nameLabel, positioned: .below, relativeTo: contentView)
        needsLayout = true
      }
    } else if let nameLabelIfLoaded, nameLabelIfLoaded.superview != nil {
      nameLabelIfLoaded.removeFromSuperview()
    }
  }

  /// The reply preview follows the plan: a reused view adds, refills or removes it.
  private func syncReplyView(for props: MessageViewProps) {
    guard props.layout.hasReply else {
      if let replyViewIfLoaded, replyViewIfLoaded.superview != nil { replyViewIfLoaded.removeFromSuperview() }
      return
    }
    replyView.setRelatedMessage(fullMessage.message)
    if let embeddedMessage = fullMessage.repliedToMessage {
      replyView.update(with: embeddedMessage, kind: .replyInMessage)
    }
    if replyView.superview !== contentView {
      contentView.addSubview(replyView, positioned: .below, relativeTo: nil)
      needsLayout = true
    }
  }

  @objc private func handleLongPress(_ gesture: NSPressGestureRecognizer) {
    let location = gesture.location(in: self)
    MessageGestureTrace.debug(
      "MinimalMessageView.handleLongPress messageId=\(message.messageId) state=\(gesture.state.rawValue) point=\(MessageGestureTrace.point(location))"
    )
    if gesture.state == .began {
      if let result = interactiveHitTestResult(location) {
        MessageGestureTrace.debug(
          "MinimalMessageView.handleLongPress messageId=\(message.messageId) blocked=interactive target=\(result.name)"
        )
        return
      }

      performConfiguredHoldAction(at: location, source: "recognizer")
    }
  }

  @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
    let location = gesture.location(in: self)
    MessageGestureTrace.debug(
      "MinimalMessageView.handleDoubleClick messageId=\(message.messageId) state=\(gesture.state.rawValue) point=\(MessageGestureTrace.point(location))"
    )
    guard gesture.state == .ended else { return }
    performConfiguredDoubleClickAction(at: location, source: "recognizer")
  }

  private func performConfiguredDoubleClickAction(at location: NSPoint, source: String) {
    performMessageGestureAction(
      AppSettings.shared.messageDoubleClickAction,
      at: location,
      source: "doubleClick.\(source)",
      blocksText: true
    )
  }

  private func performConfiguredHoldAction(at location: NSPoint, source: String) {
    performMessageGestureAction(
      AppSettings.shared.messageHoldAction,
      at: location,
      source: "hold.\(source)",
      blocksText: false
    )
  }

  private func performMessageGestureAction(
    _ action: MessageGestureAction,
    at location: NSPoint,
    source: String,
    blocksText: Bool
  ) {
    guard action != .none else { return }

    MessageGestureTrace.debug(
      "MinimalMessageView.performMessageGestureAction messageId=\(message.messageId) source=\(source) action=\(action.rawValue) point=\(MessageGestureTrace.point(location))"
    )
    if let result = interactiveHitTestResult(location),
       blocksText || !(result.view is NSTextView)
    {
      MessageGestureTrace.debug(
        "MinimalMessageView.performMessageGestureAction messageId=\(message.messageId) source=\(source) blocked=interactive target=\(result.name)"
      )
      return
    }

    if action == .toggleAck, isTextEntityPoint(location) { return }

    if blocksText, isTextPoint(location) {
      MessageGestureTrace.debug("MinimalMessageView.performMessageGestureAction messageId=\(message.messageId) source=\(source) blocked=textPoint")
      return
    }

    if action == .reply, (!fullMessage.canReply || isAnchorMessage) {
      MessageGestureTrace.debug("MinimalMessageView.performMessageGestureAction messageId=\(message.messageId) source=\(source) blocked=replyUnavailable")
      return
    }

    if action == .toggleAck, currentAcknowledgementAction() == nil {
      MessageGestureTrace.debug("MinimalMessageView.performMessageGestureAction messageId=\(message.messageId) source=\(source) blocked=ackUnavailable")
      return
    }

    // The action took this press; it must not also become a list selection drag.
    MessageListTextSelection.owner(of: self)?.cancelPendingPress()

    // Provide haptic feedback only for an action that can run.
    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)

    switch action {
    case .none:
      return
    case .reply:
      reply()
    case .reactionsMenu:
      resetGestureStateForReactionOverlay(source: source)
      showReactionOverlay()
    case .toggleAck:
      acknowledgeMessage()
    case .toggleHeart, .toggleThumbsUp:
      guard let emoji = action.reactionEmoji else { return }
      toggleReaction(AppSettings.shared.preferredEmojiSkinTone.applying(to: emoji), action: action, source: source)
    }
  }

  private func currentAcknowledgementAction() -> AcknowledgementAction? {
    guard !isAnchorMessage else { return nil }
    let currentUserId = dependencies?.auth.getCurrentUserId() ?? Auth.shared.getCurrentUserId()
    return fullMessage.acknowledgementAction(currentUserId: currentUserId)
  }

  @objc private func acknowledgeMessage() {
    guard let action = currentAcknowledgementAction() else { return }
    let targetMessage = fullMessage
    Task { [weak self] in
      do {
        try await Api.realtime.send(.acknowledgeMessages(message: targetMessage, action: action))
      } catch {
        self?.log.error("Failed to update Ack", error: error)
        ToastCenter.shared.showError("Could not update Ack")
      }
    }
  }

  private func resetGestureStateForReactionOverlay(source: String) {
    MessageGestureTrace.debug("MinimalMessageView.resetGestureStateForReactionOverlay messageId=\(message.messageId) source=\(source)")
    DispatchQueue.main.async { [weak self] in
      self?.longPressGesture?.isEnabled = false
      self?.longPressGesture?.isEnabled = true
      self?.doubleClickGesture?.isEnabled = false
      self?.doubleClickGesture?.isEnabled = true
    }
  }

  private func toggleReaction(_ emoji: String, action: MessageGestureAction, source: String) {
    guard let currentUserId = Auth.shared.getCurrentUserId() else {
      MessageGestureTrace.debug("MinimalMessageView.toggleReaction messageId=\(message.messageId) source=\(source) action=\(action.rawValue) blocked=noCurrentUser")
      return
    }
    let targetMessage = fullMessage.message
    let weReacted = fullMessage.groupedReactions
      .first(where: { $0.emoji == emoji })?
      .reactions
      .contains(where: { $0.reaction.userId == currentUserId }) ?? false

    if weReacted {
      MessageGestureTrace.debug("MinimalMessageView.toggleReaction messageId=\(message.messageId) source=\(source) action=\(action.rawValue) rpc=deleteReaction")
      Task(priority: .userInitiated) {
        do {
          try await Api.realtime.send(.deleteReaction(
            emoji: emoji,
            message: targetMessage,
          ))
        } catch {
          self.log.error("Failed to delete reaction from message gesture", error: error)
        }
      }
    } else {
      MessageGestureTrace.debug("MinimalMessageView.toggleReaction messageId=\(message.messageId) source=\(source) action=\(action.rawValue) rpc=addReaction")
      Task(priority: .userInitiated) {
        do {
          try await Api.realtime.send(.addReaction(
            emoji: emoji,
            message: targetMessage,
          ))
        } catch {
          self.log.error("Failed to add reaction from message gesture", error: error)
        }
      }
    }
  }

  private func handleAvatarClick() {
    guard !isDM else { return }
    guard let user = fullMessage.senderInfo?.user else { return }

    Task { @MainActor in
      openSenderProfile(peer: .user(id: user.id))
    }
  }

  private func openSenderProfile(peer: Peer) {
    guard let dependencies else {
      Nav.main.open(.chatInfo(peer: peer))
      return
    }

    dependencies.openChatInfo(peer: peer)
  }

  func avatarOverlayItem(in coordinateView: NSView) -> MessageAvatarOverlayItem? {
    guard usesAvatarOverlay, showsAvatar, let avatar = props.layout.avatar else { return nil }

    // The plan's height, which is the row's: a reused view keeps its previous message's height until
    // its next layout pass, which runs after the overlay sync.
    let sourceHeight = props.layout.totalHeight > 0 ? props.layout.totalHeight : bounds.height
    guard sourceHeight > 0 else { return nil }

    let top = props.layout.wrapper.spacing.top + avatar.spacing.top
    let sourceY = isFlipped ? top : sourceHeight - top
    let avatarOrigin = convert(NSPoint(x: avatar.spacing.left, y: sourceY), to: coordinateView)
    let y = coordinateView.isFlipped ? avatarOrigin.y : avatarOrigin.y - avatar.size.height
    let frame = NSRect(
      x: avatarOrigin.x,
      y: y,
      width: avatar.size.width,
      height: avatar.size.height
    )

    return MessageAvatarOverlayItem(
      stableId: fullMessage.id,
      userInfo: avatarUserInfo,
      frame: frame,
      sticky: nil,
      viaMark: fullMessage.viaPresentation?.mark
    ) { [weak self] in
      if let self {
        MessageGestureTrace.debug("MinimalMessageView.avatarOverlayClick messageId=\(self.message.messageId)")
      }
      self?.handleAvatarClick()
    }
  }

  @objc private func handleNameClick() {
    MessageGestureTrace.debug("MinimalMessageView.handleNameClick messageId=\(message.messageId)")
    handleAvatarClick()
  }

  @objc private func handleForwardHeaderClick(_: NSClickGestureRecognizer) {
    guard let forwardedMessageId = message.forwardFromMessageId else {
      MessageGestureTrace.debug("MinimalMessageView.handleForwardHeaderClick messageId=\(message.messageId) result=noForwardedMessageId")
      return
    }

    var forwardPeer: Peer?
    if let peerUserId = message.forwardFromPeerUserId {
      let currentUserId = Auth.shared.getCurrentUserId()
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
      MessageGestureTrace.debug("MinimalMessageView.handleForwardHeaderClick messageId=\(message.messageId) action=openPrivateForwardPeer")
      openChat(peer: targetPeer)
      return
    }

    if targetPeer == message.peerId {
      MessageGestureTrace.debug("MinimalMessageView.handleForwardHeaderClick messageId=\(message.messageId) action=scrollCurrentPeer")
      let chatState = ChatsManager.shared.get(for: targetPeer, chatId: message.chatId)
      chatState.scrollTo(msgId: forwardedMessageId, reason: .forwarded)
      return
    }

    MessageGestureTrace.debug("MinimalMessageView.handleForwardHeaderClick messageId=\(message.messageId) action=openForwardPeerAndScroll")
    let database = dependencies?.database ?? AppDatabase.shared
    let messageId = message.messageId
    openChat(peer: targetPeer)

    Task { @MainActor in
      guard let chat = try? await database.reader.read({ db in
        try Chat.getByPeerId(db: db, peerId: targetPeer)
      }) else {
        MessageGestureTrace.debug("MinimalMessageView.handleForwardHeaderClick messageId=\(messageId) result=noForwardPeerAccess")
        ToastCenter.shared.showError("You don't have access to that chat")
        return
      }

      let chatState = ChatsManager.shared.get(for: targetPeer, chatId: chat.id)
      chatState.scrollTo(msgId: forwardedMessageId, reason: .forwarded)
    }
  }

  // MARK: - Frame layout

  /// Places every part from the size calculator's plan, with frames: a row runs no constraints.
  ///
  /// The plan gives each part a size and outer spacings, and the tops of the parts inside the content
  /// view measured down from its top (`*ContentViewTop`). These views aren't flipped, so a part `top`
  /// points below its container's top sits at `y = containerHeight - top - height`. Sides are laid
  /// out leading to trailing and mirrored in a right-to-left layout, as leading and trailing anchors
  /// were; reactions beside an acknowledgement keep the absolute left edge they had.
  private func layoutParts() {
    let layout = props.layout
    let size = bounds.size
    updateStreamingState(requestsLayout: false)
    layoutContentParts()
    // A row is configured before its host gives it a size; the parts placed against its edges wait for one.
    guard size.width > 0, size.height > 0 else { return }
    let mirrored = userInterfaceLayoutDirection == .rightToLeft
    let contentLeading: CGFloat = if let avatar = layout.avatar {
      avatar.spacing.left + avatar.size.width + avatar.spacing.right
    } else {
      MessageSizeCalculator.minimalContentLeadingInset + MessageSizeCalculator.minimalAvatarSize
        + Theme.messageHorizontalStackSpacing
    }

    // Hover background: the row less its side insets and the wrapper's vertical spacing.
    let hoverTop = max(0, layout.wrapper.spacing.top - Theme.messageOuterVerticalPadding)
    let hoverWidth = max(0, size.width - 2 * Metrics.hoverSideInset)
    place(
      hoverBackgroundView,
      x: Metrics.hoverSideInset,
      top: hoverTop,
      size: CGSize(width: hoverWidth, height: max(0, size.height - hoverTop - layout.wrapper.spacing.bottom)),
      in: size,
      mirrored: mirrored
    )
    let contentMaxX = Metrics.hoverSideInset + hoverWidth - MessageSizeCalculator.minimalHoverContentInset

    // Bubble and content view share a frame.
    let bubbleSize = layout.bubble.size
    let nameTop = layout.wrapper.spacing.top
    let bubbleTop = layout.hasName
      ? nameTop + (layout.name?.size.height ?? 0) + (layout.name?.spacing.bottom ?? 0)
      : layout.wrapper.spacing.top
    let bubbleBottom = bubbleTop + bubbleSize.height
    place(bubbleView, x: contentLeading, top: bubbleTop, size: bubbleSize, in: size, mirrored: mirrored)
    place(contentView, x: contentLeading, top: bubbleTop, size: bubbleSize, in: size, mirrored: mirrored)

    if showsInlineAvatar, let avatar = layout.avatar, avatarView.superview === self {
      place(
        avatarView,
        x: avatar.spacing.left,
        top: avatar.spacing.top + layout.wrapper.spacing.top,
        size: avatar.size,
        in: size,
        mirrored: mirrored
      )
    }

    // The name keeps its width unless the time beside it would pass the hover background's content
    // edge: then the name gives way (it resisted compression least).
    let time = layout.time
    var nameMaxX: CGFloat?
    if showsName, let name = layout.name, nameLabel.superview === self {
      let x = contentLeading + name.spacing.left
      var available = contentMaxX - x
      if let time, timeAndStateView.superview === self {
        available -= time.spacing.left + time.size.width
      }
      let width = max(0, min(nameLabelWidth, available))
      place(
        nameLabel,
        x: x,
        top: nameTop,
        size: CGSize(width: width, height: name.size.height),
        in: size,
        mirrored: mirrored
      )
      nameMaxX = x + width
    }

    if let time, timeAndStateView.superview === self {
      if layout.hasName, let nameMaxX, let name = layout.name {
        let centerY = nameTop + name.size.height / 2 + MessageSizeCalculator.minimalInlineTimeVerticalOffset
        place(
          timeAndStateView,
          x: nameMaxX + time.spacing.left,
          top: centerY - time.size.height / 2,
          size: time.size,
          in: size,
          mirrored: mirrored
        )
      } else {
        // In the avatar gutter, before the content.
        place(
          timeAndStateView,
          x: contentLeading - time.spacing.left - time.size.width,
          top: bubbleTop + layout.topMostContentTopSpacing + MessageSizeCalculator.minimalFollowUpTimeTopOffset,
          size: time.size,
          in: size,
          mirrored: mirrored
        )
      }
    }

    // Under the bubble: action rows, then reactions placed outside it.
    var belowBubble = bubbleBottom
    if let actionsRows = layout.actionsRows, let messageActionRowsView {
      let top = bubbleBottom + actionsRows.spacing.top
      place(messageActionRowsView, x: contentLeading, top: top, size: actionsRows.size, in: size, mirrored: mirrored)
      belowBubble = top + actionsRows.size.height
    }

    if let reactionsPlan = layout.reactions, let reactionsView {
      if reactionsView.superview === self {
        let top = belowBubble + layout.reactionsOutsideBubbleTopInset
        if hasAcknowledgement {
          let bubbleLeft = mirrored ? size.width - contentLeading - bubbleSize.width : contentLeading
          place(
            reactionsView,
            x: bubbleLeft + reactionsPlan.spacing.left,
            top: top,
            size: reactionsPlan.size,
            in: size,
            mirrored: false
          )
        } else {
          place(
            reactionsView,
            x: contentLeading + reactionsPlan.spacing.left,
            top: top,
            size: reactionsPlan.size,
            in: size,
            mirrored: mirrored
          )
        }
      } else if reactionsView.superview === contentView {
        place(
          reactionsView,
          x: reactionsPlan.spacing.left,
          top: layout.reactionsViewTop,
          size: reactionsPlan.size,
          in: bubbleSize,
          mirrored: mirrored && !hasAcknowledgement
        )
      }
    }
  }

  /// Places the parts inside the content view. Their frames come from the plan alone, so they are set
  /// as soon as a row is configured: a part that keeps constraints inside (the reply preview, the
  /// attachments stack) must not join the window's layout engine at a zero size its contents can't fit.
  private func layoutContentParts() {
    let layout = props.layout
    let bubbleSize = layout.bubble.size
    let mirrored = userInterfaceLayoutDirection == .rightToLeft
    if let forwardHeader = layout.forwardHeader, let label = forwardHeaderLabelIfLoaded, label.superview === contentView {
      place(
        label,
        x: forwardHeader.spacing.left,
        top: forwardHeader.spacing.top,
        size: CGSize(
          width: bubbleSize.width - forwardHeader.spacing.left - forwardHeader.spacing.right,
          height: Theme.messageNameLabelHeight
        ),
        in: bubbleSize,
        mirrored: mirrored
      )
    }

    if let reply = layout.reply, replyView.superview === contentView {
      place(
        replyView,
        x: reply.spacing.left,
        top: layout.replyContentTop,
        size: CGSize(width: bubbleSize.width - reply.spacing.left - reply.spacing.right, height: replyView.preferredHeight),
        in: bubbleSize,
        mirrored: mirrored
      )
    }

    if let summaryView = replyThreadSummaryViewIfLoaded, summaryView.superview === contentView {
      let summary = layout.replyThreadSummary
      let left = summary?.spacing.left ?? 0
      let right = summary?.spacing.right ?? 0
      place(
        summaryView,
        x: left,
        top: layout.replyThreadSummaryContentViewTop,
        size: CGSize(
          width: bubbleSize.width - left - right,
          height: shouldShowReplyThreadSummary(for: props) ? (summary?.size.height ?? 0) : 0
        ),
        in: bubbleSize,
        mirrored: mirrored
      )
    }

    if let photo = layout.photo, let photoView = photoViewIfLoaded, photoView.superview === contentView {
      place(
        photoView,
        x: photo.spacing.left,
        top: layout.photoContentViewTop,
        size: photo.size,
        in: bubbleSize,
        mirrored: mirrored
      )
      if let albumGridView { place(albumGridView, frame: photoView.frame) }
    }

    if let video = layout.video, videoView.superview === contentView {
      place(
        videoView,
        x: video.spacing.left,
        top: layout.videoContentViewTop,
        size: video.size,
        in: bubbleSize,
        mirrored: mirrored
      )
    }

    if let document = layout.document, documentContainerView.superview === contentView {
      place(
        documentContainerView,
        x: document.spacing.left,
        top: layout.documentContentViewTop,
        size: document.size,
        in: bubbleSize,
        mirrored: mirrored
      )
    }

    if let text = layout.text, let textHost = attachedTextHost {
      place(
        textHost,
        x: text.spacing.left,
        top: layout.textContentViewTop,
        size: text.size,
        in: bubbleSize,
        mirrored: mirrored
      )
    }

    if let attachments = layout.attachments, let attachmentsView, attachmentsView.superview === contentView {
      place(
        attachmentsView,
        x: attachments.spacing.left,
        top: layout.attachmentsContentViewTop,
        size: attachments.size,
        in: bubbleSize,
        mirrored: mirrored
      )
    }
  
  }

  /// A part's frame from its leading x and its top in a container of `container` size. As with
  /// constraints, these place the part's alignment rect (a label's frame reaches past its text by
  /// its cell's padding), rounded to the backing pixels.
  private func place(_ view: NSView, x: CGFloat, top: CGFloat, size: CGSize, in container: CGSize, mirrored: Bool) {
    let rect = NSRect(
      x: mirrored ? container.width - x - size.width : x,
      y: container.height - top - size.height,
      width: size.width,
      height: size.height
    )
    place(view, frame: backingAlignedRect(view.frame(forAlignmentRect: rect), options: .alignAllEdgesNearest))
  }

  private func place(_ view: NSView, frame: NSRect) {
    guard view.frame != frame, !placesOnlyUnplacedParts || view.frame.isEmpty else { return }
    let resized = view.frame.size != frame.size
    view.frame = frame
    // A label first placed before the row had its size (truncated, or empty) doesn't redraw on its
    // own when it grows.
    if resized, view is NSTextField { view.needsDisplay = true }
  }

  /// Set while an animated update places the parts that just appeared, before the rest animate.
  private var placesOnlyUnplacedParts = false

  /// The message whose stream hides the time and status and the "Sent via" footer.
  private var timeHiddenForStream: Int64?

  /// While the body streams in (`MessageStreamPacer`), the time and status and the "Sent via" footer wait; the plan
  /// keeps their slots, so the row doesn't move when they show. The time fades in when that message's stream ends,
  /// as on iOS. Hover chrome decides the rest of the time's visibility.
  func syncStreamingState() {
    updateStreamingState(requestsLayout: true)
  }

  /// `requestsLayout`: outside a layout pass, the footer needs one to follow.
  private func updateStreamingState(requestsLayout: Bool) {
    let id = fullMessage.id
    let streaming = MessageStreamPacer.shared.isStreaming(id)
    if streaming {
      guard timeHiddenForStream != id else { return }
      timeHiddenForStream = id
      updateHoverChrome()
      if requestsLayout { needsLayout = true }
      return
    }
    guard let hiddenFor = timeHiddenForStream else { return }
    timeHiddenForStream = nil
    updateHoverChrome()
    if requestsLayout { needsLayout = true }
    guard hiddenFor == id, !timeAndStateView.isHidden else {
      timeAndStateView.alphaValue = 1
      return
    }
    timeAndStateView.alphaValue = 0
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      timeAndStateView.animator().alphaValue = 1
    }
  }

  /// The sender name's natural width, measured once per name.
  private var nameLabelWidth: CGFloat {
    let name = nameLabel.stringValue
    if let measuredNameLabelWidth, measuredNameLabelWidth.name == name { return measuredNameLabelWidth.width }
    let width = nameLabel.intrinsicContentSize.width
    measuredNameLabelWidth = (name, width)
    return width
  }

  private var measuredNameLabelWidth: (name: String, width: CGFloat)?

  override func setFrameSize(_ newSize: NSSize) {
    let changed = newSize != frame.size
    super.setFrameSize(newSize)
    if changed { needsLayout = true }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    // Frames are aligned to the backing pixels; a row laid out before it joined a window used 1x.
    needsLayout = true
  }

  private func setupMessageText() {
    guard hasText else { return }

    // Get display text which handles translations
    // TODO: Instead of using multiple computed properties, we should have do a single check here
    let translationText = fullMessage.translationText
    let translationEntities = fullMessage.translationEntities
    let text = translationText ?? fullMessage.message.text ?? ""
    let entities = translationEntities ?? fullMessage.message.entities
    let richBlockPlan = props.layout.richBlockContent
    let blockContent = richBlockPlan == nil ? nil : fullMessage.message.blockContent

    let renderCacheStyleKey = "\(richTextStyleKey)|links-v1"
    let attributedString: NSAttributedString
    if let cached = CacheAttrs.shared.get(
      message: fullMessage,
      renderStyle: .minimal,
      styleKey: renderCacheStyleKey
    ) {
      attributedString = cached
      // The cached text already carries `.link` on detected URLs, which the Core Text view reads;
      // only NSTextView still re-runs detection here (up to ~2 ms for a long message).
      detectedLinks = usesCoreText
        ? []
        : LinkDetector.shared.detectLinks(in: cached).map { (range: $0.range, url: $0.url) }
    } else {
      let codeBlockBackgroundColor = textColor.withAlphaComponent(0.05)
      let inlineCodeBackgroundColor = textColor.withAlphaComponent(0.06)
      let processed = MessageTextTypography.attributedText(
        text: text,
        entities: entities,
        fontSize: props.layout.fontSize,
        palette: richTextPalette,
        codeBlockBackgroundColor: codeBlockBackgroundColor,
        inlineCodeBackgroundColor: inlineCodeBackgroundColor
      )
      let linkMatches = LinkDetector.shared.applyLinkStyling(
        to: processed,
        linkColor: linkColor,
        cursor: NSCursor.pointingHand
      )
      for match in linkMatches {
        processed.removeAttribute(.underlineStyle, range: match.range)
        processed.removeAttribute(.underlineColor, range: match.range)
      }
      InlineTextStyle.reapply(to: processed)
      detectedLinks = linkMatches.map { (range: $0.range, url: $0.url) }
      attributedString = NSAttributedString(attributedString: processed)
      CacheAttrs.shared.set(
        message: fullMessage,
        renderStyle: .minimal,
        styleKey: renderCacheStyleKey,
        value: attributedString
      )
    }

    if let richBlockPlan, let blockContent {
      let richView = richBlockContentView ?? {
        let view = RichBlockContentView(frame: .zero)
        richBlockContentView = view
        return view
      }()
      let wasAttached = richView.superview != nil
      richView.onTextEntityClick = { [weak self] hit, text in
        self?.handleTextEntityClick(hit, attributedString: text) ?? false
      }
      richView.onTextLongPress = { [weak self] event in
        guard let self else { return }
        handleTextLongPress(at: textHostView.convert(event.locationInWindow, from: nil), event: event)
      }
      richView.onMessageAction = { [weak self] action in
        self?.handleMessageActionTap(action)
      }
      richView.onCompose = { [weak self] text in
        self?.postCompose(text)
      }
      richView.onDisclosureToggle = { [weak self] path, expanded in
        guard let self else { return }
        RichBlockMessageActions.toggleDisclosure(
          path: path,
          expanded: expanded,
          message: self.fullMessage.message
        )
      }
      // The rich blocks draw everything; their host only places them.
      let host = textHostView
      if let coreTextView, usesCoreText {
        coreTextView.setMessageAttributedString(
          NSAttributedString(),
          isRtl: props.isRtl,
          layoutSize: props.layout.text?.size ?? .zero,
          linkColor: linkColor
        )
      } else {
        textView.setMessageAttributedString(
          NSAttributedString(),
          isRtl: props.isRtl,
          layoutSize: props.layout.text?.size ?? .zero,
          useTextKit2: useTextKit2
        )
      }
      if richView.superview !== host {
        richView.removeFromSuperview()
        host.addSubview(richView)
      }
      host.setAccessibilityElement(true)
      host.setAccessibilityRole(.group)
      host.setAccessibilityChildren([richView])
      richView.frame = CGRect(origin: .zero, size: richBlockPlan.size)
      richView.update(
        plan: richBlockPlan,
        content: blockContent,
        attributedText: attributedString,
        baseFontSize: props.layout.fontSize,
        palette: richBlockPalette,
        relatedMessage: fullMessage.message,
        codePresentation: props.richBlockCodePresentation,
        renderStyle: .minimal,
        animated: wasAttached
      )
      detectedLinks = []
      return
    }

    richBlockContentView?.prepareForReuse()
    richBlockContentView?.removeFromSuperview()
    if usesCoreText {
      coreTextView?.setAccessibilityRole(.staticText)
      coreTextView?.setAccessibilityChildren(nil)
      coreTextView?.setMessageAttributedString(
        attributedString,
        isRtl: props.isRtl,
        layoutSize: props.layout.text?.size ?? .zero,
        linkColor: linkColor
      )
      return
    }
    textView.setAccessibilityElement(true)
    textView.setAccessibilityRole(.textArea)
    textView.setAccessibilityChildren(nil)
    textView.setMessageAttributedString(
      attributedString,
      isRtl: props.isRtl,
      layoutSize: props.layout.text?.size ?? .zero,
      useTextKit2: useTextKit2
    )
  }

  func reflectBoundsChange(fraction _: CGFloat) {}

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    richBlockContentView?.setContentVisible(window != nil)

    if window == nil {
      quickActionsMenu?.cancelTracking()
      updateHoverState(false)
    }

    setupBoundsChangeObserver()
    setupScrollStateObserver()
  }

  private var boundsChangeObserver: NSObjectProtocol?

  private func setupBoundsChangeObserver() {
    if let observer = boundsChangeObserver {
      NotificationCenter.default.removeObserver(observer)
      boundsChangeObserver = nil
    }

    // Experimental in build 66
    // Adjust viewport instead of layouting
    // Only NSTextView needs it: the Core Text view has no viewport to keep laid out.
    if superview != nil, window != nil, !usesCoreText, let clipView = enclosingScrollView?.contentView {
      // Register for both frame and bounds changes
//      NotificationCenter.default.addObserver(
//        self,
//        selector: #selector(handleBoundsChange),
//        name: NSView.frameDidChangeNotification,
//        object: enclosingScrollView?.contentView
//      )

      ////      // Also observe bounds changes
      boundsChangeObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: clipView,
        queue: .main
      ) { [weak self] notification in
        self?.handleBoundsChange(notification)
      }

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
    guard hasText, !usesCoreText else { return }
    // guard textView.inLiveResize else { return }

    let visibleRect = scrollView.documentVisibleRect
    let textViewRect = convert(bounds, to: clipView)
    let inViewport = visibleRect.insetBy(dx: 0.0, dy: 60.0).intersects(
      textViewRect
    )

    if !prevInViewport, inViewport {
      if textView.inLiveResize, MessageTextConfiguration.useTextKit2ViewportWorkarounds {
        // Avoid forcing TextKit 2 viewport layout on macOS 27; crash reports show
        // AppKit throwing from this path during NSTableView row install.
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

  var quickActionsCanReact: Bool {
    message.status != .sending && message.status != .failed
  }

  var quickActionsCanReply: Bool {
    quickActionsCanReact && !isAnchorMessage
  }

  func quickActionsAnchorRect(in coordinateView: NSView) -> NSRect {
    let anchor = convert(hoverBackgroundView.frame, to: coordinateView)
    let offset: CGFloat = props.layout.hasAvatar && props.layout.hasName ? 4 : 10
    return anchor.offsetBy(dx: 0, dy: coordinateView.isFlipped ? -offset : offset)
  }

  func performQuickAction(
    _ action: MessageQuickActionsView.Action,
    from button: NSButton,
    capsule: NSView
  ) -> ReactionOverlayWindow? {
    guard window != nil else { return nil }
    focusWindowIfNeeded()

    switch action {
      case .replyInThread:
        guard quickActionsCanReply else { return nil }
        replyInThread()
      case .reaction:
        guard quickActionsCanReact else { return nil }
        guard let capsuleWindow = capsule.window else { return nil }
        let anchorRect = capsuleWindow.convertToScreen(capsule.convert(capsule.bounds, to: nil))
        return showReactionOverlay(above: anchorRect)
      case .more:
        let contextMenu = createMenu(context: .message)
        // The accessory is a sibling of the row. Preserve message ownership rather than
        // resolving untargeted actions through the accessory's responder chain.
        for item in contextMenu.items where item.action != nil && item.target == nil {
          item.target = self
        }
        // Kept so scrolling and hover-out can cancel it, as they did the pull-down.
        quickActionsMenu = contextMenu
        // Opens off the button's lower edge, like a pull-down.
        let below = NSPoint(x: button.bounds.minX, y: button.isFlipped ? button.bounds.maxY + 4 : button.bounds.minY - 4)
        ContextMenu.popUp(contextMenu, at: below, in: button)
    }
    return nil
  }

  /// The message menu is built when it opens, in `menu(for:)`: right clicks anywhere in the message
  /// (documents, voice, rich blocks included) bubble up to it, and text views ask through their
  /// delegates. No view keeps a menu of its own.
  private func setupContextMenu() {
    menu = nil
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    ContextMenu.intercept(createMenu(context: .message), for: event, in: self)
  }

  /// VoiceOver's and Full Keyboard Access's show-menu on the message.
  override func accessibilityPerformShowMenu() -> Bool {
    ContextMenu.showForAccessibility(in: self) { createMenu(context: .message) }
  }

  @objc private func addReaction() {
    focusWindowIfNeeded()
    // Show reaction overlay
    showReactionOverlay()
  }

  @objc private func copyMessage() {
    // A rich body copies its blocks, so headings, lists, code and tables keep their shape.
    if let richBlockContentView, richBlockContentView.superview != nil, !richBlockContentView.isHidden,
       let document = richBlockContentView.textSelectionProjection()?.structuredWholeMessageDocument(),
       MessageClipboard.write(document)
    {
      return
    }
    MessageTextPasteboard.copy(
      text: fullMessage.displayText ?? "",
      entities: fullMessage.translationEntities ?? message.entities
    )
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

  @objc private func copyMessageLink() {
    ChatMenuActions.copyMessageLink(
      chatId: message.chatId,
      messageId: message.messageId
    )
  }

  @objc private func deleteMessage() {
    if let album = props.album {
      let sentCount = album.items.count(where: { $0.message.messageId > 0 })
      guard sentCount > 0 else { return deleteAlbum(album) }
      MessageDeletion.confirm(count: sentCount, in: window) { [weak self] in self?.deleteAlbum(album) }
      return
    }
    // Never reached the server: cancel a send in flight, or remove a failed one locally.
    if message.status == .failed || message.messageId <= 0 {
      if message.status != .failed, PendingMessageCanceller.cancel(fullMessage) { return }
      let messageId = message.messageId
      let chatId = message.chatId
      let peerId = message.peerId
      Task {
        _ = try? await AppDatabase.shared.dbWriter.write { db in
          try Message.deleteMessages(db, messageIds: [messageId], chatId: chatId)
        }
        await MainActor.run {
          MessagesPublisher.shared.messagesDeleted(messageIds: [messageId], peer: peerId)
        }
      }
      return
    }

    let message = message
    MessageDeletion.confirm(count: 1, in: window) {
      Task(priority: .userInitiated) { @MainActor in
        await MessageDeletion.deleteShowingErrors(
          messageIds: [message.messageId],
          peerId: message.peerId,
          chatId: message.chatId
        )
      }
    }
  }

  /// An album goes as a whole: sent items on the server, sends in flight cancelled, failed
  /// ones locally.
  private func deleteAlbum(_ album: MessageAlbum) {
    let peerId = message.peerId
    let chatId = message.chatId
    let sent = album.items.map(\FullMessage.message.messageId).filter { $0 > 0 }
    let cancelled = album.items.filter { $0.message.messageId <= 0 && PendingMessageCanceller.cancel($0) }
    let local = album.items.filter { item in
      item.message.messageId <= 0 && !cancelled.contains { $0.id == item.id }
    }.map(\FullMessage.message.messageId)
    if !local.isEmpty {
      Task {
        _ = try? await AppDatabase.shared.dbWriter.write { db in
          try Message.deleteMessages(db, messageIds: local, chatId: chatId)
        }
        await MainActor.run { MessagesPublisher.shared.messagesDeleted(messageIds: local, peer: peerId) }
      }
    }
    if !sent.isEmpty {
      Task(priority: .userInitiated) { @MainActor in
        await MessageDeletion.deleteShowingErrors(messageIds: sent, peerId: peerId, chatId: chatId)
      }
    }
  }

  @objc private func pinMessage() {
    guard !isAnchorMessage else { return }
    Task(priority: .userInitiated) { @MainActor in
      let peer = chatPeerId()
      try await Api.realtime.send(.pinMessage(
        peer: peer,
        messageId: message.messageId,
        unpin: false
      ))
    }
  }

  @objc private func unpinMessage() {
    guard !isAnchorMessage else { return }
    Task(priority: .userInitiated) { @MainActor in
      let peer = chatPeerId()
      try await Api.realtime.send(.pinMessage(
        peer: peer,
        messageId: message.messageId,
        unpin: true
      ))
    }
  }

  private func chatPeerId() -> Peer {
    return message.peerId
  }

  @objc private func reply() {
    guard !isAnchorMessage else { return }
    let state = ChatsManager
      .get(
        for: fullMessage.peerId,
        chatId: fullMessage.chatId
      )

    state.setReplyingToMsgId(fullMessage.message.messageId)
  }

  /// Selected text in this message, captured when the menu opens. A selection that spans
  /// rich blocks wins; otherwise the focused text view's own selection is used.
  private func selectedTextForQuote() -> String? {
    let selected: String?
    if let text = MessageListTextSelection.owner(of: self)?.selectedText(onlyIn: self) {
      selected = text
    } else if let textView = window?.firstResponder as? NSTextView, textView.isDescendant(of: self),
              textView.selectedRange().length > 0 {
      selected = (textView.string as NSString).substring(with: textView.selectedRange())
    } else {
      selected = nil
    }
    let trimmed = selected?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  @objc private func quoteSelection(_ sender: NSMenuItem) {
    guard !isAnchorMessage, let quoted = sender.representedObject as? String else { return }
    ChatsManager
      .get(for: fullMessage.peerId, chatId: fullMessage.chatId)
      .quote(MessageMarkdown.quoteLines(quoted), replyingTo: fullMessage.message.messageId)
  }

  @objc private func replyInThread() {
    openReplyThreadFlow(
      source: .menu,
      action: AppSettings.shared.openReplyThreadsInSidePane ? .sidePane : .current
    )
  }

  private func makeReplyThreadSummaryMenu() -> NSMenu {
    let menu = ContextMenu()
    if !message.isSubthreadPlacement {
      menu.addItem(replyThreadMenuItem(
        title: "Open in Side Pane",
        systemSymbolName: "arrow.turn.down.right",
        action: #selector(openReplyThreadInSidePaneFromSummaryMenu)
      ))
    }
    menu.addItem(replyThreadMenuItem(
      title: message.isSubthreadPlacement ? "Open Subthread" : "Open as Chat",
      systemSymbolName: "arrow.up.left.and.arrow.down.right",
      action: #selector(openReplyThreadAsChatFromSummaryMenu)
    ))
    menu.addItem(replyThreadMenuItem(
      title: "Copy Link",
      systemSymbolName: "link",
      action: #selector(copyReplyThreadLinkFromSummaryMenu)
    ))
    menu.addItem(replyThreadMenuItem(
      title: "Open in Sidebar",
      systemSymbolName: "sidebar.left",
      action: #selector(addReplyThreadToInboxFromSummaryMenu)
    ))
    if message.isSubthreadPlacement {
      menu.addItem(.separator())
      menu.addItem(replyThreadMenuItem(
        title: "Delete",
        systemSymbolName: "trash",
        action: #selector(deleteMessage)
      ))
    }
    return menu
  }

  private func replyThreadMenuItem(
    title: String,
    systemSymbolName: String,
    action: Selector
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = !isAnchorMessage
    item.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: title)
    return item
  }

  @objc private func openReplyThreadInSidePaneFromSummaryMenu() {
    openReplyThreadFlow(source: .menu, action: .sidePane)
  }

  @objc private func openReplyThreadAsChatFromSummaryMenu() {
    openReplyThreadFlow(source: .menu, action: .current)
  }

  @objc private func copyReplyThreadLinkFromSummaryMenu() {
    guard !isAnchorMessage else { return }

    Task { @MainActor in
      do {
        let peer = try await resolveReplyThreadPeerForMenuAction()
        guard let url = replyThreadDeepLinkURL(for: peer) else {
          throw ReplyThreadOpenError.invalidResponse
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        ToastCenter.shared.showSuccess("Copied link")
      } catch {
        ToastCenter.shared.showError("Failed to copy link")
        log.error("Failed to copy reply thread link", error: error)
      }
    }
  }

  @objc private func addReplyThreadToInboxFromSummaryMenu() {
    guard !isAnchorMessage else { return }

    Task { @MainActor in
      do {
        guard let dependencies else {
          throw ReplyThreadOpenError.invalidResponse
        }

        let peer = try await resolveReplyThreadPeerForMenuAction()
        ToastCenter.shared.showLoading("Opening in sidebar…")

        _ = try await dependencies.realtimeV2.send(.updateDialogFollowMode(peerId: peer, selection: .following))
        try await InboxMembershipService.shared.open(peer: peer)

        ToastCenter.shared.dismiss()
        ToastCenter.shared.showSuccess("Opened in sidebar")
      } catch {
        ToastCenter.shared.dismiss()
        ToastCenter.shared.showError("Couldn’t open in sidebar")
        log.error("Failed to add reply thread to inbox", error: error)
      }
    }
  }

  @MainActor
  private func resolveReplyThreadPeerForMenuAction() async throws -> Peer {
    if let existingPeer = message.replyThreadPeer {
      return existingPeer
    }

    guard let dependencies else {
      throw ReplyThreadOpenError.invalidResponse
    }

    ToastCenter.shared.showLoading("Creating thread…")
    defer {
      ToastCenter.shared.dismiss()
    }

    let rpcResult = try await dependencies.realtimeV2.send(
      .createSubthread(
        parentChatId: message.chatId,
        parentMessageId: message.messageId
      )
    )

    guard case let .createSubthread(response) = rpcResult, response.hasChat else {
      throw ReplyThreadOpenError.invalidResponse
    }

    return .thread(id: response.chat.id)
  }

  private func replyThreadDeepLinkURL(for peer: Peer) -> URL? {
    switch peer {
    case let .user(id):
      InlineDeepLink.user(id: id).url
    case let .thread(id):
      InlineDeepLink.chat(id: id).url
    }
  }

  private func openReplyThreadFlow(
    source: ReplyThreadOpenSource,
    action: ReplyThreadOpenAction
  ) {
    guard !isAnchorMessage else { return }
    let action = message.isSubthreadPlacement ? ReplyThreadOpenAction.current : action
    if source == .threadSummary, action == .sidePane,
       let existingPeer = message.replyThreadPeer,
       dependencies?.closeReplyThreadPaneIfShowing(existingPeer) == true
    {
      return
    }
    if action.usesCurrentWindowPresentation {
      focusWindowIfNeeded()
    }
    let useInlineSpinner =
      source == .threadSummary
      && hasReplyThreadSummary
      && action.usesCurrentWindowPresentation

    if useInlineSpinner {
      replyThreadSummaryViewIfLoaded?.setLoading(true)
    }

    Task { @MainActor in
      defer {
        if useInlineSpinner {
          replyThreadSummaryViewIfLoaded?.setLoading(false)
        }
      }

      guard let dependencies else {
        ToastCenter.shared.showError("Failed to open thread")
        return
      }

      if let existingPeer = message.replyThreadPeer {
        openReplyThread(peer: existingPeer, dependencies: dependencies, action: action)
        return
      }

      // Open on a reserved id right away; history and sends wait for the server.
      if let reservedChatId = await dependencies.realtimeV2.createReplyThreadLocally(
        parentChatId: message.chatId,
        parentMessageId: message.messageId
      ) {
        openReplyThread(peer: .thread(id: reservedChatId), dependencies: dependencies, action: action)
        return
      }

      if !useInlineSpinner {
        ToastCenter.shared.showLoading("Creating thread…")
      }

      do {
        let rpcResult = try await dependencies.realtimeV2.send(
          .createSubthread(
            parentChatId: message.chatId,
            parentMessageId: message.messageId
          )
        )

        guard case let .createSubthread(response) = rpcResult, response.hasChat else {
          throw ReplyThreadOpenError.invalidResponse
        }

        let threadPeer: Peer = .thread(id: response.chat.id)

        if !useInlineSpinner {
          ToastCenter.shared.dismiss()
        }
        openReplyThread(peer: threadPeer, dependencies: dependencies, action: action)
      } catch {
        if !useInlineSpinner {
          ToastCenter.shared.dismiss()
        }
        ToastCenter.shared.showError("Failed to open thread")
        log.error("Failed to open reply thread", error: error)
      }
    }
  }

  private func openReplyThread(
    peer: Peer,
    dependencies: AppDependencies,
    action: ReplyThreadOpenAction
  ) {
    switch action {
    case .sidePane:
      dependencies.openReplyThreadInPane(
        parentPeer: message.peerId,
        threadPeer: peer,
        sourceMessageId: message.messageId
      )
    case .current:
      dependencies.openChatRoute(peer: peer)
    case .newTab:
      MainWindowOpenCoordinator.shared.openTab(.chat(peer: peer))
    }
  }

  @objc private func selectMessagesForForwarding() {
    MessageSelectionCoordinator.beginSelection(from: self)
  }

  @objc private func forwardMessage() {
    if let forwardMessages = dependencies?.forwardMessages {
      // An album forwards as a whole and stays one album in the destination.
      forwardMessages.present(messages: props.album?.items ?? [fullMessage])
      return
    }

    guard let window, let presentingController = window.contentViewController else { return }

    var dismissForwardSheet: (() -> Void)?
    var sheetClickMonitor: Any?
    var escapeKeyMonitor: Any?
    var sheetCloseObserver: Any?
    var isDismissingForwardSheet = false

    weak var weakHostingController: NSViewController?
    let rootView = ForwardMessagesSheet(
      messages: props.album?.items ?? [fullMessage],
      onSelect: { [weak self] destination, selection in
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
      },
      onSend: { [weak self] destinations, selection in
        guard let self else { return }
        await self.forwardMessages(destinations: destinations, selection: selection)
      },
      onClose: {
        dismissForwardSheet?()
      }
    )
    .appDatabase(AppDatabase.shared)

    let hostingController = NSHostingController(rootView: AnyView(rootView))
    weakHostingController = hostingController
    hostingController.title = "Forward"
    hostingController.preferredContentSize = NSSize(width: 480, height: 560)

    let cleanupForwardSheetDismissHandlers = {
      if let monitor = sheetClickMonitor {
        NSEvent.removeMonitor(monitor)
        sheetClickMonitor = nil
      }
      if let monitor = escapeKeyMonitor {
        NSEvent.removeMonitor(monitor)
        escapeKeyMonitor = nil
      }
      if let observer = sheetCloseObserver {
        NotificationCenter.default.removeObserver(observer)
        sheetCloseObserver = nil
      }
    }

    dismissForwardSheet = { [weak presentingController] in
      guard !isDismissingForwardSheet else { return }
      isDismissingForwardSheet = true
      cleanupForwardSheetDismissHandlers()
      guard let hostingController = weakHostingController else { return }
      presentingController?.dismiss(hostingController)
    }

    presentingController.presentAsSheet(hostingController)
    DispatchQueue.main.async { [weak hostingController] in
      guard let hostingController, let sheetWindow = hostingController.view.window else { return }
      sheetWindow.title = "Forward"
      sheetWindow.styleMask.insert(.closable)
      sheetWindow.standardWindowButton(.closeButton)?.isHidden = false

      sheetCloseObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification,
        object: sheetWindow,
        queue: .main
      ) { _ in
        cleanupForwardSheetDismissHandlers()
      }

      sheetClickMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .rightMouseDown]
      ) { event in
        guard !isDismissingForwardSheet else { return event }
        if let eventWindow = event.window, eventWindow === sheetWindow {
          return event
        }
        dismissForwardSheet?()
        return event
      }

      escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard !isDismissingForwardSheet else { return event }
        guard event.keyCode == 53 else { return event } // Esc
        dismissForwardSheet?()
        return nil
      }
    }
  }

  private func openChat(peer: Peer) {
    guard let dependencies else {
      Nav.main.open(.chat(peer: peer))
      return
    }

    dependencies.requestOpenChat(peer: peer)
  }

  private func messageSpaceId() -> Int64? {
    guard message.peerId.isThread else { return nil }
    if didResolveMessageSpaceId {
      return resolvedMessageSpaceId
    }
    loadMessageSpaceIdIfNeeded()
    return nil
  }

  private func loadMessageSpaceIdIfNeeded() {
    guard message.peerId.isThread, !didResolveMessageSpaceId, !isResolvingMessageSpaceId else {
      return
    }

    isResolvingMessageSpaceId = true
    let database = dependencies?.database ?? AppDatabase.shared
    let chatId = message.chatId
    Task { [weak self] in
      do {
        let spaceId = try await database.reader.read { db in
          try Chat.fetchOne(db, id: chatId)?.spaceId
        }
        await MainActor.run {
          guard let self else { return }
          guard self.message.chatId == chatId else { return }
          self.resolvedMessageSpaceId = spaceId
          self.didResolveMessageSpaceId = true
          self.isResolvingMessageSpaceId = false
        }
      } catch {
        Log.shared.error("Failed to resolve message chat space", error: error)
        await MainActor.run {
          guard let self else { return }
          guard self.message.chatId == chatId else { return }
          self.isResolvingMessageSpaceId = false
        }
      }
    }
  }

  private func messageHasLinearAccess() -> Bool {
    let service = LinearIntegrationService.shared

    if message.peerId.isThread {
      guard let spaceId = messageSpaceId() else { return false }
      let connected = service.isConnected(spaceId: spaceId)
      if connected == nil {
        service.refresh(spaceId: spaceId)
      }
      return connected == true
    }

    let connected = service.isConnectedAnySpace()
    if connected == nil {
      service.refreshAnySpace()
    }
    return connected == true
  }

  @MainActor
  private func forwardMessages(
    destinations: [HomeChatItem],
    selection: ForwardMessagesSheet.ForwardMessagesSelection
  ) async {
    guard !destinations.isEmpty else { return }
    guard !selection.messageIds.isEmpty else {
      log.error("Forward failed: empty message ids")
      return
    }

    for destination in destinations {
      let destinationPeer = destination.peerId
      do {
        let result = try await Api.realtime.send(.forwardMessages(
          fromPeerId: selection.fromPeerId,
          toPeerId: destinationPeer,
          messageIds: selection.messageIds
        ))

        if case let .forwardMessages(response) = result, response.updates.isEmpty {
          _ = await Api.realtime.sendQueued(.getChatHistory(peer: destinationPeer))
        }
      } catch {
        log.error("Forward failed", error: error)
      }
    }

    ToastCenter.shared.showSuccess("Forwarded to \(destinations.count) chats")
  }

  @objc private func editMessage() {
    guard !isAnchorMessage else { return }
    let state = ChatsManager
      .get(
        for: fullMessage.peerId,
        chatId: fullMessage.chatId
      )

    state.setEditingMsgId(fullMessage.message.messageId)
  }

  @objc private func handleWillDo() {
    guard !isAnchorMessage else { return }
    guard let window else { return }

    Task { @MainActor in
      let spaceId: Int64? = if message.peerId.isThread {
        messageSpaceId()
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
    guard !isAnchorMessage else { return }
    guard let window else { return }

    Task { @MainActor in
      let spaceId: Int64? = if message.peerId.isThread {
        messageSpaceId()
      } else {
        nil
      }
      await LinearIssueCoordinator.shared.handleCreateLinearIssue(
        message: message,
        spaceId: spaceId,
        window: window
      )
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

  @objc private func saveAudio() {
    VoiceMessageAudioSaver.save(message: message, window: window)
  }

  // MARK: - View Updates

  private func updatePropsAndUpdateLayout(
    props: MessageViewProps,
    disableTextRelayout _: Bool = false,
    textFollows: Bool = false,
    animate: Bool = false
  ) {
    // update internal props (must update so contentView is recalced)
    self.props = props

    // Nothing is laid out here: frames follow the plan in `layout()`, and the list lays the row out
    // on its next pass. `setLayoutWidth` only marks the width for that pass, and new text that
    // follows (row reuse) lays out at it at once, so the text lays out once, at the new width.
    // Animating, the pass below runs before the next message's text, so its width waits for it.
    if usesCoreText {
      if !(textFollows && animate) { coreTextView?.setLayoutWidth(props.layout.text?.size.width ?? 0) }
    } else if isNativeTextViewLoaded, textView.textContainer?.size != props.layout.text?.size ?? .zero {
      log.trace("updating size for text in msg \(message.id)")
      textView.textContainer?.size = props.layout.text?.size ?? .zero
    }
    needsLayout = true

    if animate {
      // Parts that just appeared take their frames at once; the others move to theirs.
      placesOnlyUnplacedParts = true
      layoutParts()
      placesOnlyUnplacedParts = false
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        context.allowsImplicitAnimation = true

        // self.animator().layoutSubtreeIfNeeded()
        self.layoutSubtreeIfNeeded()
      } completionHandler: { [weak self] in
        // Completion block
        DispatchQueue.main.async {
          // Avoid forcing TextKit 2 viewport layout on macOS 27; crash reports show
          // AppKit throwing from this path during NSTableView row install.
          guard MessageTextConfiguration.useTextKit2ViewportWorkarounds else { return }
          // Fixes text display issues going blank
          guard let self, !self.usesCoreText, self.isNativeTextViewLoaded else { return }
          self.textView.textLayoutManager?.textViewportLayoutController
            .layoutViewport()
        }
      }
      if textFollows, usesCoreText { coreTextView?.setLayoutWidth(props.layout.text?.size.width ?? 0) }
    }
  }

  func updateTextAndSize(fullMessage: FullMessage, props: MessageViewProps, animate: Bool = false) {
    log.trace(
      "Updating message view content. from: \(self.fullMessage.message.messageId) to: \(fullMessage.message.messageId)"
    )

    let prev = self.fullMessage
    if prev.message.stableId != fullMessage.message.stableId {
      quickActionsMenu?.cancelTracking()
    }

    prevInViewport = false

    // Ensure media views exist before constraint updates when reusing the view
    if props.layout.photo != nil, photoView.superview == nil {
      contentView.addSubview(photoView)
    }

    if props.layout.video != nil, videoView.superview == nil {
      contentView.addSubview(videoView)
    }

    // update internal props
    self.fullMessage = fullMessage
    configureAcknowledgement(animated: animate)
    needsLayout = true
    if prev.message.chatId != fullMessage.message.chatId {
      didResolveMessageSpaceId = false
      isResolvingMessageSpaceId = false
      resolvedMessageSpaceId = nil
    }
    syncForwardHeaderView(for: props)
    syncMessageActionRowsView(message: fullMessage, props: props)
    syncUploadProgressView(props: props)

    if props.layout.document != nil {
      if documentContainerView.superview == nil {
        contentView.addSubview(documentContainerView)
      }
      syncDocumentSlotView()
    } else {
      documentContainerView.removeFromSuperview()
    }

    if props.layout.attachments != nil, attachmentsView == nil {
      attachmentsView = createAttachmentsView()
      if let attachmentsView {
        contentView.addSubview(attachmentsView)
      }
    } else if props.layout.attachments != nil, let attachmentsView, attachmentsView.superview == nil {
      contentView.addSubview(attachmentsView)
    }

    // Reply preview: added, refilled or removed
    syncReplyView(for: props)
    updateReplyThreadSummaryView(for: props)

    // Update props and reflect changes
    updatePropsAndUpdateLayout(props: props, disableTextRelayout: true, textFollows: true, animate: animate)

    syncSenderViews()
    if showsViaFooter || viaFooterLabel?.isHidden == false {
      needsLayout = true
    }

    // Reactions
    // TODO: Reactions are not updating as expected
    updateReactions(prev: prev, next: fullMessage, props: props)

    // Text
    syncTextViewForCurrentProps()
    setupMessageText()

    // Update bubble background
    bubbleView.backgroundColor = bubbleBackgroundColor

    syncForwardHeaderView(for: props)

    // Photo
    // Under an album the photo view only holds the slot: nothing to load.
    if hasPhoto, props.album == nil {
      photoView.update(with: fullMessage)
    } else if !hasPhoto, let photoViewIfLoaded, photoViewIfLoaded.superview != nil {
      // A reused view showing a message without the photo (`MessageTableCell.configure` allows only that change).
      photoViewIfLoaded.removeFromSuperview()
    }
    syncAlbumGrid()

    // Video
    if hasVideo {
      if videoView.superview == nil {
        contentView.addSubview(videoView)
      }
      videoView.update(with: fullMessage)
    } else if let videoViewIfLoaded, videoViewIfLoaded.superview != nil {
      videoViewIfLoaded.removeFromSuperview()
    }

    // Document
    if hasDocument {
      syncDocumentSlotView()
    }

    if hasAttachments {
      if let attachmentsView {
        attachmentsView.configure(
          attachments: fullMessage.attachments,
          message: fullMessage.message,
          usesOutgoingBubbleStyle: false
        )
        attachmentsView.apply(itemPlans: props.layout.attachmentItems)
      } else {
        attachmentsView = createAttachmentsView()
        contentView.addSubview(attachmentsView!)
      }
    } else {
      attachmentsView?.removeFromSuperview()
      attachmentsView = nil
    }

    // Update time and state
    timeAndStateView.updateMessage(
      fullMessage,
      overlay: isTimeOverlay,
      contentAlignment: timeContentAlignment
    )
    updateHoverChrome()

    // Ensure swipe UI is reset if message cannot be replied to
    if !self.fullMessage.canReply || self.isAnchorMessage {
      layer?.transform = CATransform3DIdentity
      swipeAnimationView?.alphaValue = 0
      isSwipeInProgress = false
      hasTriggerHapticFeedback = false
      didReachThreshold = false
    }

    needsLayout = true
    layoutContentParts()
  }

  func updateSize(props: MessageViewProps) {
    needsLayout = true
    // update props and reflect changes
    updatePropsAndUpdateLayout(
      props: props,
      // disableTextRelayout: props.layout.singleLine // Quick hack to reduce such re-layouts
      disableTextRelayout: true
    )
    syncAlbumGrid()
    attachmentsView?.apply(itemPlans: props.layout.attachmentItems)

    if let richBlockPlan = props.layout.richBlockContent,
       let richBlockContentView
    {
      richBlockContentView.frame = CGRect(origin: .zero, size: richBlockPlan.size)
      richBlockContentView.applyLayout(richBlockPlan, animated: false)
    }

    // if hasReactions {
    updateReactionsSizes()
    // }
    layoutContentParts()
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
          albumGridView?.setIsScrolling(false)
        } else {
          photoView.setIsScrolling(true)
          albumGridView?.setIsScrolling(true)
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

  private func setupScrollStateObserver() {
    if let observer = notificationObserver {
      NotificationCenter.default.removeObserver(observer)
      notificationObserver = nil
    }

    guard superview != nil, window != nil, let scrollView = enclosingScrollView else { return }
    notificationObserver = NotificationCenter.default.addObserver(
      forName: .messageListScrollStateDidChange,
      object: scrollView,
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
  private var swipeDirection = MessageSwipeToReplyDirection.defaultValue
  private var swipeAnimationView: NSView?
  private var hasTriggerHapticFeedback = false
  private var swipeThreshold: CGFloat = 50.0
  private var didReachThreshold = false
  private var avatarSwipeProvider: MessageAvatarSwipeProvider?
  private weak var swipedAvatarOverlayView: NSView?

  func setAvatarSwipeProvider(_ provider: MessageAvatarSwipeProvider?) {
    avatarSwipeProvider = provider
  }

  override func scrollWheel(with event: NSEvent) {
    if richBlockContentView?.consumeNestedHorizontalScroll(event) == true {
      resetSwipePresentation()
      return
    }
    // Do not allow swipe-to-reply if message cannot be replied to
    if !fullMessage.canReply || isAnchorMessage {
      // Ensure UI is reset and pass through
      resetSwipePresentation()
      super.scrollWheel(with: event)
      return
    }
    // Only handle horizontal scrolling with two fingers
    if event.phase == .began, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
      // Start of a horizontal scroll
      isSwipeInProgress = true
      swipeOffset = 0
      swipeDirection = AppSettings.shared.messageSwipeToReplyDirection
      hasTriggerHapticFeedback = false
      didReachThreshold = false
      swipedAvatarOverlayView?.layer?.transform = CATransform3DIdentity
      swipedAvatarOverlayView = avatarSwipeProvider?(self)
      swipedAvatarOverlayView?.wantsLayer = true

      // Create animation view if needed
      if swipeAnimationView == nil {
        swipeAnimationView = createReplyIndicator()
        addSubview(swipeAnimationView!, positioned: .below, relativeTo: nil)
        swipeAnimationView?.alphaValue = 0
      }

      // Position the animation view
      if let animView = swipeAnimationView {
        let yPosition = bubbleView.bounds.midY - animView.bounds.height / 2
        let xPosition = swipeDirection.revealsLeftEdge ? -animView.bounds.width : bounds.width
        animView.frame.origin = NSPoint(x: xPosition, y: yPosition)
      }
    }

    if isSwipeInProgress {
      swipeOffset += event.scrollingDeltaX

      if swipeDirection.accepts(swipeOffset) {
        // Calculate swipe progress (0 to 1)
        let progress = min(1.0, abs(swipeOffset) / swipeThreshold)

        // Update position using layer transform on self
        let maxOffset: CGFloat = 40.0
        let offset = swipeDirection.boundedOffset(swipeOffset, maximum: maxOffset)

        // Apply transform to root view layer
        wantsLayer = true
        let transform = CATransform3DMakeTranslation(offset, 0, 0)
        layer?.transform = transform
        swipedAvatarOverlayView?.layer?.transform = transform

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
        // Reset motion opposite the configured reply direction.
        layer?.transform = CATransform3DIdentity
        swipedAvatarOverlayView?.layer?.transform = CATransform3DIdentity
        swipeAnimationView?.alphaValue = 0
      }

      // End of swipe gesture
      if event.phase == .ended || event.phase == .cancelled {
        isSwipeInProgress = false

        // Check if swipe was far enough to trigger reply
        if abs(swipeOffset) > swipeThreshold, swipeDirection.accepts(swipeOffset) {
          // Guard again in case state changed mid-gesture
          guard fullMessage.canReply, !isAnchorMessage else {
            // Reset and exit
            NSAnimationContext.runAnimationGroup { context in
              context.duration = 0.2
              context.allowsImplicitAnimation = true
              context.timingFunction = CAMediaTimingFunction(name: .easeOut)
              self.layer?.transform = CATransform3DIdentity
              self.swipedAvatarOverlayView?.layer?.transform = CATransform3DIdentity
              swipeAnimationView?.animator().alphaValue = 0
            }
            swipedAvatarOverlayView = nil
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
            self.swipedAvatarOverlayView?.layer?.transform = CATransform3DIdentity
            swipeAnimationView?.animator().alphaValue = 0
          }) {}
        } else {
          // Not far enough, just animate back
          NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.layer?.transform = CATransform3DIdentity
            self.swipedAvatarOverlayView?.layer?.transform = CATransform3DIdentity
            swipeAnimationView?.animator().alphaValue = 0
          }
        }

        // Reset state
        swipedAvatarOverlayView = nil
        hasTriggerHapticFeedback = false
        didReachThreshold = false
      }
    } else {
      // Pass the event to super if we're not handling it
      super.scrollWheel(with: event)
    }
  }

  private func resetSwipePresentation() {
    layer?.transform = CATransform3DIdentity
    swipedAvatarOverlayView?.layer?.transform = CATransform3DIdentity
    swipedAvatarOverlayView = nil
    swipeAnimationView?.alphaValue = 0
    isSwipeInProgress = false
    swipeOffset = 0
    hasTriggerHapticFeedback = false
    didReachThreshold = false
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
    container.layer?.backgroundColor = Theme.accentColor.withAlphaComponent(0.2).cgColor

    // Add reply icon (smaller size)
    let iconView = NSImageView(frame: NSRect(x: 4, y: 4, width: 16, height: 16))
    if let replyImage = NSImage(systemSymbolName: "arrowshape.turn.up.left.fill", accessibilityDescription: "Reply") {
      iconView.image = replyImage
      iconView.contentTintColor = Theme.accentColor
      container.addSubview(iconView)
    }

    return container
  }

  func reset() {
    quickActionsMenu?.cancelTracking()
    resetSwipePresentation()

    // Cancel translation state observation
    translationStateCancellable?.cancel()
    translationStateCancellable = nil

    // Remove shine effect
    shineEffectView?.stopAnimation()
    shineEffectView?.removeFromSuperview()
    shineEffectView = nil
    replyThreadSummaryViewIfLoaded?.clear()
    updateHoverState(false)

    // Re-setup translation state observation
    setupTranslationStateObservation()
  }

  @objc private func cancelMessage() {
    PendingMessageCanceller.cancel(fullMessage)
  }

  @objc private func resendMessage() {
    let failedMessage = fullMessage
    Task { @MainActor in
      do { try await FailedMessageResender.resend(failedMessage) }
      catch { ToastCenter.shared.showError(error.localizedDescription) }
    }
  }
}

extension MinimalMessageViewAppKit: AppThemeRefreshable {
  func refreshAppTheme() {
    swipeAnimationView?.removeFromSuperview()
    swipeAnimationView = nil
    setupMessageText()
  }
}

// MARK: - Tracking Area & Hover

extension MinimalMessageViewAppKit {
  private struct InteractiveHitResult {
    let name: String
    let view: NSView
  }

  private func interactiveHitTestResult(_ point: NSPoint) -> InteractiveHitResult? {
    if let richBlockContentView, richBlockContentView.superview != nil, !richBlockContentView.isHidden,
       let hit = richBlockContentView.interactiveImageHitTest(richBlockContentView.convert(point, from: self))
    {
      return InteractiveHitResult(name: "richImage", view: hit)
    }

    if let richBlockContentView, richBlockContentView.superview != nil,
       let hit = richBlockContentView.interactiveTextHitTest(richBlockContentView.convert(point, from: self)) {
      return InteractiveHitResult(name: "rich-text", view: hit)
    }

    if let reactionsView {
      let pointInReactions = reactionsView.convert(point, from: self)
      if let hit = reactionsView.interactiveHitTest(pointInReactions) {
        MessageGestureTrace.trace(
          "MinimalMessageView.interactiveHitTest messageId=\(message.messageId) target=reactions point=\(MessageGestureTrace.point(point)) local=\(MessageGestureTrace.point(pointInReactions)) hit=\(type(of: hit))"
        )
        return InteractiveHitResult(name: "reactions", view: hit)
      }
    }

    if let messageActionRowsView {
      let pointInActions = messageActionRowsView.convert(point, from: self)
      if let hit = messageActionRowsView.hitTest(pointInActions) {
        MessageGestureTrace.trace(
          "MinimalMessageView.interactiveHitTest messageId=\(message.messageId) target=actions point=\(MessageGestureTrace.point(point)) local=\(MessageGestureTrace.point(pointInActions)) hit=\(type(of: hit))"
        )
        return InteractiveHitResult(name: "actions", view: hit)
      }
    }

    if let attachmentsView, attachmentsView.superview != nil, !attachmentsView.isHidden {
      let pointInAttachments = attachmentsView.convert(point, from: self)
      if let hit = attachmentsView.interactiveHitTest(pointInAttachments) {
        MessageGestureTrace.trace(
          "MinimalMessageView.interactiveHitTest messageId=\(message.messageId) target=attachments point=\(MessageGestureTrace.point(point)) local=\(MessageGestureTrace.point(pointInAttachments)) hit=\(type(of: hit))"
        )
        return InteractiveHitResult(name: "attachments", view: hit)
      }
    }

    if hasPhoto, photoView.superview != nil, !photoView.isHidden {
      let pointInPhoto = photoView.convert(point, from: self)
      if let hit = photoView.hitTest(pointInPhoto) {
        MessageGestureTrace.trace(
          "MinimalMessageView.interactiveHitTest messageId=\(message.messageId) target=photo point=\(MessageGestureTrace.point(point)) local=\(MessageGestureTrace.point(pointInPhoto)) hit=\(type(of: hit))"
        )
        return InteractiveHitResult(name: "photo", view: hit)
      }
    }

    if hasVideo, videoView.superview != nil, !videoView.isHidden {
      let pointInVideo = videoView.convert(point, from: self)
      if let hit = videoView.hitTest(pointInVideo) {
        MessageGestureTrace.trace(
          "MinimalMessageView.interactiveHitTest messageId=\(message.messageId) target=video point=\(MessageGestureTrace.point(point)) local=\(MessageGestureTrace.point(pointInVideo)) hit=\(type(of: hit))"
        )
        return InteractiveHitResult(name: "video", view: hit)
      }
    }

    if hasDocument, documentContainerView.superview != nil, !documentContainerView.isHidden {
      let pointInDocument = documentContainerView.convert(point, from: self)
      if let hit = documentContainerView.hitTest(pointInDocument) {
        MessageGestureTrace.trace(
          "MinimalMessageView.interactiveHitTest messageId=\(message.messageId) target=document point=\(MessageGestureTrace.point(point)) local=\(MessageGestureTrace.point(pointInDocument)) hit=\(type(of: hit))"
        )
        return InteractiveHitResult(name: "document", view: hit)
      }
    }

    if hasReply, replyView.superview != nil, !replyView.isHidden {
      let pointInReply = replyView.convert(point, from: self)
      if let hit = replyView.hitTest(pointInReply) {
        MessageGestureTrace.trace(
          "MinimalMessageView.interactiveHitTest messageId=\(message.messageId) target=reply point=\(MessageGestureTrace.point(point)) local=\(MessageGestureTrace.point(pointInReply)) hit=\(type(of: hit))"
        )
        return InteractiveHitResult(name: "reply", view: hit)
      }
    }

    if shouldShowReplyThreadSummary(for: props),
       let replyThreadSummaryView = replyThreadSummaryViewIfLoaded,
       replyThreadSummaryView.superview != nil,
       !replyThreadSummaryView.isHidden {
      let pointInSummary = replyThreadSummaryView.convert(point, from: self)
      if let hit = replyThreadSummaryView.hitTest(pointInSummary) {
        MessageGestureTrace.trace(
          "MinimalMessageView.interactiveHitTest messageId=\(message.messageId) target=replyThreadSummary point=\(MessageGestureTrace.point(point)) local=\(MessageGestureTrace.point(pointInSummary)) hit=\(type(of: hit))"
        )
        return InteractiveHitResult(name: "replyThreadSummary", view: hit)
      }
    }

    if showsInlineAvatar, let avatarSuperview = avatarView.superview {
      // `UserAvatarView.hitTest` takes the point in its superview's coordinates (AppKit's contract).
      let pointInAvatar = avatarSuperview.convert(point, from: self)
      if let hit = avatarView.hitTest(pointInAvatar) {
        MessageGestureTrace.trace(
          "MinimalMessageView.interactiveHitTest messageId=\(message.messageId) target=avatar point=\(MessageGestureTrace.point(point)) local=\(MessageGestureTrace.point(pointInAvatar)) hit=\(type(of: hit))"
        )
        return InteractiveHitResult(name: "avatar", view: hit)
      }
    }

    if showsName, nameLabel.superview != nil {
      let pointInName = nameLabel.convert(point, from: self)
      if let hit = nameLabel.hitTest(pointInName) {
        MessageGestureTrace.trace(
          "MinimalMessageView.interactiveHitTest messageId=\(message.messageId) target=name point=\(MessageGestureTrace.point(point)) local=\(MessageGestureTrace.point(pointInName)) hit=\(type(of: hit))"
        )
        return InteractiveHitResult(name: "name", view: hit)
      }
    }

    MessageGestureTrace.trace(
      "MinimalMessageView.interactiveHitTest messageId=\(message.messageId) point=\(MessageGestureTrace.point(point)) target=nil"
    )
    return nil
  }

  private func isTextViewPoint(_ point: NSPoint) -> Bool {
    guard let textView = attachedTextHost, !textView.isHidden else { return false }
    return textView.bounds.contains(textView.convert(point, from: self))
  }

  private func isTextPoint(_ point: NSPoint) -> Bool {
    guard let textView = attachedTextHost, !textView.isHidden else {
      MessageGestureTrace.trace("MinimalMessageView.isTextPoint messageId=\(message.messageId) point=\(MessageGestureTrace.point(point)) result=false reason=noTextView")
      return false
    }

    let pointInText = textView.convert(point, from: self)
    guard textView.bounds.contains(pointInText) else {
      MessageGestureTrace.trace(
        "MinimalMessageView.isTextPoint messageId=\(message.messageId) point=\(MessageGestureTrace.point(point)) textPoint=\(MessageGestureTrace.point(pointInText)) result=false reason=outOfBounds"
      )
      return false
    }

    guard let messageTextView = textSurface else {
      MessageGestureTrace.trace(
        "MinimalMessageView.isTextPoint messageId=\(message.messageId) point=\(MessageGestureTrace.point(point)) textPoint=\(MessageGestureTrace.point(pointInText)) result=true reason=plainTextView"
      )
      return true
    }

    let codeRange = messageTextView.codeBlockRange(at: pointInText)
    let inlineRange = messageTextView.inlineCodeRange(at: pointInText)
    let renderedText = messageTextView.renderedTextContains(pointInText)
    let result = codeRange != nil || inlineRange != nil || renderedText
    MessageGestureTrace.trace(
      "MinimalMessageView.isTextPoint messageId=\(message.messageId) point=\(MessageGestureTrace.point(point)) textPoint=\(MessageGestureTrace.point(pointInText)) result=\(result) code=\(MessageGestureTrace.range(codeRange)) inline=\(MessageGestureTrace.range(inlineRange)) rendered=\(renderedText)"
    )
    return result
  }

  func setScrollState(_ state: MessageListScrollState) {
    handleScrollStateChange(state)
  }

  func setListHoverState(_ isHovered: Bool) {
    updateHoverState(isHovered)
  }

  func containsListHoverPoint(_ point: NSPoint, from coordinateView: NSView) -> Bool {
    let localPoint = convert(point, from: coordinateView)
    return hoverBackgroundView.frame.contains(localPoint)
  }

  private func handleScrollStateChange(_ state: MessageListScrollState) {
    scrollState = state
    switch state {
      case .scrolling:
        // Clear hover state
        updateHoverState(false)
      case .idle:
        break
    }
  }

  var shouldAlwaysShowTimeAndState: Bool {
    message.status == .sending || message.status == .failed
  }

  private var hoverBackgroundColor: NSColor {
    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    return NSColor.labelColor.withAlphaComponent(isDark ? 0.05 : 0.025)
  }

  private func updateHoverChrome() {
    hoverBackgroundView.backgroundColor = isMouseInside ? hoverBackgroundColor : nil
    hoverBackgroundView.isHidden = !isMouseInside
    let showsTimeAndState = (showsAvatar || shouldAlwaysShowTimeAndState) && timeHiddenForStream == nil
    timeAndStateView.isHidden = !showsTimeAndState
    // Most rows sit mid-group with the time hidden; they register no date tooltip.
    timeAndStateView.showsToolTip = showsTimeAndState
  }

  private func updateHoverState(_ isHovered: Bool) {
    guard isMouseInside != isHovered else { return }
    isMouseInside = isHovered
    updateHoverChrome()
  }
}

// MARK: - NSGestureRecognizerDelegate

extension MinimalMessageViewAppKit: NSGestureRecognizerDelegate {
  func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
    let result = shouldHandleMessageGesture(gestureRecognizer, event: event)
    MessageGestureTrace.debug(
      "MinimalMessageView.delegate.shouldAttempt messageId=\(message.messageId) recognizer=\(recognizerName(gestureRecognizer)) event=\(eventSummary(event)) allow=\(result)"
    )

    if result,
       gestureRecognizer === doubleClickGesture,
       event.type == .leftMouseDown,
       event.clickCount == 2
    {
      // Run the configured double-click action at the second mouse-down boundary. Returning false keeps
      // the recognizer action fallback from firing a duplicate when it does work.
      if handledDoubleClickEventNumber == event.eventNumber {
        MessageGestureTrace.debug(
          "MinimalMessageView.delegate.shouldAttempt messageId=\(message.messageId) recognizer=doubleClick eventNumber=\(event.eventNumber) action=skipDuplicateDoubleClick"
        )
        return false
      }

      handledDoubleClickEventNumber = event.eventNumber
      let location = convert(event.locationInWindow, from: nil)
      MessageGestureTrace.debug(
        "MinimalMessageView.delegate.shouldAttempt messageId=\(message.messageId) recognizer=doubleClick eventNumber=\(event.eventNumber) action=handleDoubleClickInDelegate"
      )
      performConfiguredDoubleClickAction(at: location, source: "delegate")
      return false
    }

    return result
  }

  private func shouldHandleMessageGesture(_ gestureRecognizer: NSGestureRecognizer, event: NSEvent) -> Bool {
    let locationInSelf = convert(event.locationInWindow, from: nil)

    if (gestureRecognizer === longPressGesture || gestureRecognizer === doubleClickGesture),
       event.type != .leftMouseDown
    {
      MessageGestureTrace.debug(
        "MinimalMessageView.shouldHandleGesture messageId=\(message.messageId) recognizer=\(recognizerName(gestureRecognizer)) point=\(MessageGestureTrace.point(locationInSelf)) allow=false reason=nonPrimaryMouse"
      )
      return false
    }

    if gestureRecognizer === longPressGesture, event.clickCount > 1 {
      MessageGestureTrace.debug(
        "MinimalMessageView.shouldHandleGesture messageId=\(message.messageId) recognizer=\(recognizerName(gestureRecognizer)) point=\(MessageGestureTrace.point(locationInSelf)) allow=false reason=multiClick"
      )
      return false
    }

    if gestureRecognizer === longPressGesture, isTextViewPoint(locationInSelf) {
      MessageGestureTrace.debug(
        "MinimalMessageView.shouldHandleGesture messageId=\(message.messageId) recognizer=\(recognizerName(gestureRecognizer)) point=\(MessageGestureTrace.point(locationInSelf)) allow=false reason=textHoldFallback"
      )
      return false
    }

    if gestureRecognizer === longPressGesture, isTextEntityPoint(locationInSelf) {
      MessageGestureTrace.debug(
        "MinimalMessageView.shouldHandleGesture messageId=\(message.messageId) recognizer=\(recognizerName(gestureRecognizer)) point=\(MessageGestureTrace.point(locationInSelf)) allow=false reason=textEntity"
      )
      return false
    }

    if gestureRecognizer === doubleClickGesture {
      if isTextEntityPoint(locationInSelf) { return false }
      if handleEntityClick(from: event, source: recognizerName(gestureRecognizer)) {
        MessageGestureTrace.debug(
          "MinimalMessageView.shouldHandleGesture messageId=\(message.messageId) recognizer=\(recognizerName(gestureRecognizer)) point=\(MessageGestureTrace.point(locationInSelf)) allow=false reason=entityClick"
        )
        return false
      }

      // Preserve native word selection for every configured action, including Ack.
      if isTextPoint(locationInSelf) {
        MessageGestureTrace.debug(
          "MinimalMessageView.shouldHandleGesture messageId=\(message.messageId) recognizer=\(recognizerName(gestureRecognizer)) point=\(MessageGestureTrace.point(locationInSelf)) allow=false reason=textPoint"
        )
        return false
      }
    }

    if let result = interactiveHitTestResult(locationInSelf) {
      MessageGestureTrace.debug(
        "MinimalMessageView.shouldHandleGesture messageId=\(message.messageId) recognizer=\(recognizerName(gestureRecognizer)) point=\(MessageGestureTrace.point(locationInSelf)) allow=false reason=interactive target=\(result.name)"
      )
      return false
    }

    MessageGestureTrace.debug(
      "MinimalMessageView.shouldHandleGesture messageId=\(message.messageId) recognizer=\(recognizerName(gestureRecognizer)) point=\(MessageGestureTrace.point(locationInSelf)) allow=true"
    )
    return true
  }

  func gestureRecognizer(
    _ gestureRecognizer: NSGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
  ) -> Bool {
    let allow = (gestureRecognizer === longPressGesture && otherGestureRecognizer === doubleClickGesture)
      || (gestureRecognizer === doubleClickGesture && otherGestureRecognizer === longPressGesture)
    MessageGestureTrace.debug(
      "MinimalMessageView.delegate.simultaneous messageId=\(message.messageId) lhs=\(recognizerName(gestureRecognizer)) rhs=\(recognizerName(otherGestureRecognizer)) allow=\(allow)"
    )
    return allow
  }

  private func recognizerName(_ gestureRecognizer: NSGestureRecognizer) -> String {
    if gestureRecognizer === longPressGesture { return "longPress" }
    if gestureRecognizer === doubleClickGesture { return "doubleClick" }
    return String(describing: type(of: gestureRecognizer))
  }

  private func eventSummary(_ event: NSEvent) -> String {
    let point = convert(event.locationInWindow, from: nil)
    return "\(MessageGestureTrace.eventDescription(event)) local=\(MessageGestureTrace.point(point))"
  }
}

// MARK: - Selection menu

extension MinimalMessageViewAppKit: MessageSelectionMenuProviding {
  func messageSelectionMenuItems() -> [MessageSelectionMenu.Item] {
    let regularMessage = message.status != .sending && message.status != .failed
    guard regularMessage, !isAnchorMessage, let quoted = selectedTextForQuote() else { return [] }
    return [
      .init(title: "Quote") { [weak self] in
        guard let self, !self.isAnchorMessage else { return }
        ChatsManager
          .get(for: self.fullMessage.peerId, chatId: self.fullMessage.chatId)
          .quote(MessageMarkdown.quoteLines(quoted), replyingTo: self.fullMessage.message.messageId)
      },
    ]
  }
}

// MARK: - NSTextViewDelegate

extension MinimalMessageViewAppKit: NSTextViewDelegate, RichBlockTextMenuProviding {
  func textViewDidChangeSelection(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }
    guard textView.selectedRanges.contains(where: { $0.rangeValue.length > 0 }) else { return }
    MessageGestureTrace.debug("MinimalMessageView.textSelectionChanged messageId=\(message.messageId) action=dismissReactionOverlay")
    ReactionOverlayWindow.dismiss(for: self)
  }

  func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
    let linkURL = linkURLForContextMenu(at: charIndex)
    return ContextMenu.intercept(createMenu(context: .textView, nativeMenu: menu, linkURL: linkURL), for: event, in: textView)
  }

  func richBlockTextMenu(
    nativeMenu: NSMenu,
    event _: NSEvent,
    characterIndex: Int,
    attributedText: NSAttributedString
  ) -> NSMenu? {
    let linkURL = linkURL(at: characterIndex, in: attributedText)
    let menu = createMenu(context: .textView, nativeMenu: nativeMenu, linkURL: linkURL)
    return menu
  }

  func richBlockMessageMenu() -> NSMenu {
    let menu = createMenu(context: .message)
    return menu
  }

  // func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
  //   // Handle our custom detected links
  //   handleLinkClick(at: charIndex)
  //   return true
  // }
}

extension MinimalMessageViewAppKit: NSMenuDelegate {
  enum MenuContext {
    case message
    case textView
  }

  func createMenu(context: MenuContext, nativeMenu: NSMenu? = nil, linkURL: URL? = nil) -> NSMenu {
    MessageListTextSelection.retargetCopy(
      in: createMessageMenu(context: context, nativeMenu: nativeMenu, linkURL: linkURL),
      from: self
    )
  }

  private func createMessageMenu(context: MenuContext, nativeMenu: NSMenu?, linkURL: URL?) -> NSMenu {
    // Inline's own context menu: it can carry the reactions bar, and the same items show in our panels.
    // Groups: answer, copy, media and files, change, integrations, the text view's own items, then
    // the destructive action and footnotes.
    let menu = ContextMenu()

    let regularMessage = quickActionsCanReact

    // Reactions live in the bar above the menu (+ opens the full picker in place).
    if regularMessage {
      menu.options.accessoryConfiguration = MessageReactionActions.contextMenuAccessoryConfiguration
      menu.accessoryViewProvider = { [weak self] in
        guard let self else { return nil }
        return MessageReactionActions.contextMenuAccessory(for: fullMessage)
      }
    }

    func addSection(_ items: [NSMenuItem]) {
      guard !items.isEmpty else { return }
      if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
        menu.addItem(.separator())
      }
      items.forEach { menu.addItem($0) }
    }

    // Answer: reply, quote, thread, forward.
    var answerItems: [NSMenuItem] = []
    if regularMessage, !isAnchorMessage {
      let replyItem = NSMenuItem(title: "Reply", action: #selector(reply), keyEquivalent: "r")
      replyItem.image = NSImage(systemSymbolName: "arrowshape.turn.up.left", accessibilityDescription: "Reply")
      answerItems.append(replyItem)

      // Quote is offered only while part of this message is selected.
      if let quoted = selectedTextForQuote() {
        let quoteItem = NSMenuItem(title: "Quote", action: #selector(quoteSelection(_:)), keyEquivalent: "")
        quoteItem.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Quote")
        quoteItem.representedObject = quoted
        answerItems.append(quoteItem)
      }

      let replyInThreadItem = NSMenuItem(
        title: message.isSubthreadPlacement ? "Open Subthread" : "Reply in Thread",
        action: #selector(replyInThread),
        keyEquivalent: ""
      )
      replyInThreadItem.image = NSImage(
        systemSymbolName: "arrowshape.turn.up.left.circle",
        accessibilityDescription: message.isSubthreadPlacement ? "Open Subthread" : "Reply in Thread"
      )
      answerItems.append(replyInThreadItem)

      if !message.isSubthreadPlacement {
        let forwardItem = NSMenuItem(title: "Forward", action: #selector(forwardMessage), keyEquivalent: "")
        forwardItem.image = NSImage(systemSymbolName: "arrowshape.turn.up.right", accessibilityDescription: "Forward")
        if ExperimentalFeatureFlags.quickForwardEnabled, let dependencies,
           dependencies.forwardMessages != nil {
          forwardItem.submenu = ForwardMessageMenu.make(messages: props.album?.items ?? [fullMessage], dependencies: dependencies)
        }
        answerItems.append(forwardItem)
      }
    }
    addSection(answerItems)

    // Copy: the message, the selection, a link under the pointer, the message link, the image.
    var copyItems: [NSMenuItem] = []
    if hasText {
      let copyItem = NSMenuItem(title: "Copy Text", action: #selector(copyMessage), keyEquivalent: "c")
      copyItem.image = NSImage(systemSymbolName: "document.on.document", accessibilityDescription: "Copy")
      copyItems.append(copyItem)

      if canCopyMessageWithEntities {
        let debugCopyItem = NSMenuItem(
          title: "Copy Message + Entities",
          action: #selector(copyMessageWithEntities),
          keyEquivalent: ""
        )
        copyItems.append(debugCopyItem)
      }
    }

    if context == .textView,
       let nativeMenu,
       let nativeCopyItem = nativeMenu.items.first(where: { $0.action == #selector(NSText.copy(_:)) })
    {
      let newItem = nativeCopyItem.copy() as! NSMenuItem
      newItem.title = "Copy Selected Text"
      newItem.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: nil)
      copyItems.append(newItem)
    }

    if context == .textView, let linkURL {
      let copyLinkItem = NSMenuItem(
        title: "Copy Link Address",
        action: #selector(copyLinkAddress),
        keyEquivalent: ""
      )
      copyLinkItem.target = self
      copyLinkItem.representedObject = linkURL
      copyLinkItem.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Copy Link")
      copyItems.append(copyLinkItem)
    }

    if regularMessage,
       InlineDeepLink.message(chatId: message.chatId, messageId: message.messageId).url != nil {
      let copyMessageLinkItem = NSMenuItem(
        title: "Copy Message Link",
        action: #selector(copyMessageLink),
        keyEquivalent: ""
      )
      copyMessageLinkItem.target = self
      copyMessageLinkItem.image = NSImage(
        systemSymbolName: "link",
        accessibilityDescription: "Copy Message Link"
      )
      copyItems.append(copyMessageLinkItem)
    }

    // An album's photos open one at a time, from their tiles.
    if hasPhoto, props.album == nil {
      let copyItem = NSMenuItem(title: "Copy Image", action: #selector(photoView.copyImage), keyEquivalent: "i")
      copyItem.target = photoView
      copyItem.isEnabled = true
      copyItem.image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Copy Image")
      copyItems.append(copyItem)
    }
    addSection(copyItems)

    // Media and files.
    if hasPhoto {
      let saveItem = NSMenuItem(title: "Save Image", action: #selector(photoView.saveImage), keyEquivalent: "m")
      saveItem.target = photoView
      saveItem.isEnabled = true
      saveItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save Image")
      addSection([saveItem])
    }

    if hasVideo {
      var videoItems: [NSMenuItem] = []
      let openItem = NSMenuItem(title: "Open Video", action: #selector(videoView.openQuickLook), keyEquivalent: "v")
      openItem.target = videoView
      openItem.isEnabled = true
      openItem.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "Play")
      videoItems.append(openItem)

      let saveItem = NSMenuItem(
        title: "Save Video",
        action: #selector(videoView.saveVideo),
        keyEquivalent: "s"
      )
      saveItem.target = videoView
      saveItem.isEnabled = true
      saveItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save Video")
      videoItems.append(saveItem)

      if videoView.canSaveAsGIF {
        let saveGIFItem = NSMenuItem(
          title: "Save GIF",
          action: #selector(videoView.saveGIF),
          keyEquivalent: "g"
        )
        saveGIFItem.target = videoView
        saveGIFItem.isEnabled = true
        saveGIFItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save GIF")
        videoItems.append(saveGIFItem)
      }
      addSection(videoItems)
    }

    // The message's file, or the album file under the mouse.
    if hasActualDocument || albumFileRowUnderMouse != nil {
      if menu.items.last?.isSeparatorItem == false {
        menu.addItem(.separator())
      }
      if hasActualDocument {
        documentView?.appendContextMenuItems(to: menu)
      } else if let row = albumFileRowUnderMouse {
        row.appendContextMenuItems(to: menu)
      }
    }

    if canSaveLoadedVoice {
      let saveItem = NSMenuItem(title: "Save Audio", action: #selector(saveAudio), keyEquivalent: "s")
      saveItem.target = self
      saveItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save Audio")
      addSection([saveItem])
    }

    // Change: edit (own messages), pin, select.
    var changeItems: [NSMenuItem] = []
    if !isAnchorMessage, !message.isSubthreadPlacement, !message.isGridTranscript, message.out == true,
       message.status == .sent
    {
      let editItem = NSMenuItem(title: "Edit", action: #selector(editMessage), keyEquivalent: "e")
      editItem.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Edit")
      changeItems.append(editItem)
    }

    if regularMessage, !isAnchorMessage {
      let pinned = isMessagePinned()
      let pinTitle = pinned ? "Unpin" : "Pin"
      let pinAction = pinned ? #selector(unpinMessage) : #selector(pinMessage)
      let pinItem = NSMenuItem(title: pinTitle, action: pinAction, keyEquivalent: "")
      pinItem.image = NSImage(
        systemSymbolName: pinned ? "pin.slash" : "pin",
        accessibilityDescription: pinTitle
      )
      changeItems.append(pinItem)
    }

    if regularMessage, !isAnchorMessage, !message.isSubthreadPlacement, message.messageId > 0,
       message.status == nil || message.status == .sent
    {
      let selectItem = NSMenuItem(
        title: "Select", action: #selector(selectMessagesForForwarding), keyEquivalent: ""
      )
      selectItem.target = self
      selectItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
      changeItems.append(selectItem)
    }
    addSection(changeItems)

    // Integrations.
    var integrationItems: [NSMenuItem] = []

    if regularMessage, !isAnchorMessage, NotionTaskService.shared.hasAccess(peerId: message.peerId) {
      let willDoItem = NSMenuItem(title: "Create Notion Task", action: #selector(handleWillDo), keyEquivalent: "")
      willDoItem.image = NSImage(
        systemSymbolName: "circle.badge.plus",
        accessibilityDescription: "Create Notion Task"
      )
      integrationItems.append(willDoItem)
    }

    if regularMessage, !isAnchorMessage, hasText {
      if messageHasLinearAccess() {
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
    addSection(integrationItems)

    // The text view's own items for the click: Look Up, Translate.
    if context == .textView, let nativeMenu {
      var textItems: [NSMenuItem] = []
      for item in nativeMenu.items {
        if item.title.hasPrefix("Look Up") {
          let newItem = item.copy() as! NSMenuItem
          newItem.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Look Up")
          textItems.append(newItem)
        }

        if item.title.hasPrefix("Translate") {
          let newItem = item.copy() as! NSMenuItem
          newItem.image = NSImage(systemSymbolName: "translate", accessibilityDescription: "Translate")
          textItems.append(newItem)
        }
      }
      addSection(textItems)
    }

    // Resend, then delete or cancel.
    var destructiveItems: [NSMenuItem] = []
    if message.status == .failed {
      let resendItem = NSMenuItem(title: "Resend", action: #selector(resendMessage), keyEquivalent: "")
      resendItem.target = self
      resendItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Resend")
      destructiveItems.append(resendItem)
    }

    if message.status == .sending {
      let cancelTitle = fullMessage.showsPhotoUploadProgress ? "Cancel Upload" : "Cancel"
      let cancelItem = NSMenuItem(title: cancelTitle, action: #selector(cancelMessage), keyEquivalent: "\u{8}")
      cancelItem.target = self
      cancelItem.image = NSImage(systemSymbolName: "x.circle", accessibilityDescription: cancelTitle)
      cancelItem.contextMenuStyle = .destructive
      destructiveItems.append(cancelItem)
    } else {
      let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteMessage), keyEquivalent: "\u{8}")
      deleteItem.target = self
      deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")
      deleteItem.contextMenuStyle = .destructive
      destructiveItems.append(deleteItem)
    }
    addSection(destructiveItems)

    // Footnotes: small text under the actions (disabled rows in the system menu).
    func addFootnote(_ title: String) {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.isEnabled = false
      item.contextMenuStyle = .footnote
      menu.addItem(item)
    }

    if let editDate = message.editDate {
      let formatted = DateFormatter.localizedString(from: editDate, dateStyle: .medium, timeStyle: .short)
      addFootnote("Edited \(formatted)")
    }

    if let attribution = fullMessage.acknowledgementAttributionLabel {
      addFootnote(attribution)
    }

    #if DEBUG
    addFootnote("ID: \(message.id) · Index: \(props.index?.description ?? "?")")
    #endif

    menu.delegate = self
    return menu
  }
}

//// Implement viewport constraint
extension MinimalMessageViewAppKit: NSTextViewportLayoutControllerDelegate {
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

// MARK: - Text selection across blocks and messages

extension MinimalMessageViewAppKit: MessageTextSelectionSource {
  func textSelectionProjection() -> MessageTextSelectionProjection? {
    if let richBlockContentView, richBlockContentView.superview != nil, !richBlockContentView.isHidden {
      return richBlockContentView.textSelectionProjection()
    }
    guard let textView = textSurface, textView.superview != nil, !textView.isHiddenOrHasHiddenAncestor,
          textView.surfaceText.length > 0
    else { return nil }
    return .single(textView)
  }

  func textSelectionPressRegion() -> CGRect? {
    let container: NSView = if let richBlockContentView, richBlockContentView.superview != nil, !richBlockContentView.isHidden {
      richBlockContentView
    } else if let host = attachedTextHost {
      host
    } else {
      self
    }
    guard container !== self, container.window != nil, !container.isHiddenOrHasHiddenAncestor else { return nil }
    // The text with a margin for imprecise presses, and the whole bubble around it.
    var region = convert(container.bounds, from: container).insetBy(dx: -10, dy: -10)
    if bubbleView.superview != nil, !bubbleView.isHidden, !bubbleView.frame.isEmpty {
      region = region.union(convert(bubbleView.bounds, from: bubbleView).insetBy(dx: -6, dy: -6))
    }
    return region
  }

  func isInteractiveForTextSelection(at point: NSPoint) -> Bool {
    guard let result = interactiveHitTestResult(point) else { return false }
    return !(result.view is NSTextView) && !(result.view is any MessageTextSurface)
  }
}
