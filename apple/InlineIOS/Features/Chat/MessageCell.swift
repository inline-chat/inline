import InlineIOSUI
import InlineKit
import InlineTheme
import InlineUI
import Logger
import SwiftUI
import Translation
import UIKit

protocol MessageCellDelegate: AnyObject {
  func didSwipeToReply(for message: FullMessage)
}

class MessageCollectionViewCell: UICollectionViewCell, UIGestureRecognizerDelegate {
  private struct SelfSizingTraitSignature: Equatable {
    let contentSizeCategory: UIContentSizeCategory
    let displayScale: CGFloat
    let layoutDirection: UITraitEnvironmentLayoutDirection
  }

  private struct PendingV2Snapshot {
    let message: FullMessage
    let animatedReactionEmoji: String?
  }

  static let reuseIdentifier = "MessageCell"
  static let sendAnimationHorizontalPadding: CGFloat = 8
  /// Keeps the reply control centered on the same side guide as 42-point controls
  /// with a 16-point outer inset, regardless of the indicator's own frame size.
  private static let replyIndicatorSideCenterInset: CGFloat = 37
  private static let contentTransform = CGAffineTransform(scaleX: 1, y: -1)
  private static let insertionContentTransform = contentTransform.scaledBy(x: 0.985, y: 0.985)

  var messageView: UIMessageView? {
    didSet { updateContextMenuSourceVisibility() }
  }
  var isContextMenuSourceHidden = false {
    didSet { updateContextMenuSourceVisibility() }
  }

  private func updateContextMenuSourceVisibility() {
    guard let messageView else { return }
    let source: UIView = messageView.fullMessage.message.isServiceMessage
      ? messageView.serviceContainerView : messageView.bubbleView
    source.isHidden = isContextMenuSourceHidden
  }

  private var messageRootView: UIView?
  var avatarView: UserAvatarView?
  var avatarSpacerView: UIView?

  weak var delegate: MessageCellDelegate?
  var onUserTap: ((Int64) -> Void)?
  var onReactionsMenu: ((FullMessage) -> Void)?
  var messageActionsMenuProvider: ((MessageCollectionViewCell) -> UIMenu)? {
    didSet { setNeedsLayout() }
  }
  var allowsMessageActions = false {
    didSet { setNeedsLayout() }
  }
  private(set) var messageHoldAction = MessageGestureAction.defaultHold
  var onPhotoTap: ((FullMessage, UIView, UIImage?, URL) -> Void)?
  var grabOverlappingAvatar: ((UIView) -> UIView?)?
  var onV2GeometryChange: ((
    MessageCollectionViewCell,
    MessageBubbleLayoutV2,
    MessageBubbleLayoutV2
  ) -> Void)?
  private var panGesture: UIPanGestureRecognizer!
  private var swipeActive = false
  private var initialTranslation: CGFloat = 0
  private var swipeDirection = MessageSwipeToReplyDirection.defaultValue
  private weak var swipedAvatarOverlayView: UIView?
  private var prevText: String?
  private var canReply: Bool = true
  private(set) var isPreparedForSendAnimationTarget = false
  private var selfSizingHeightStabilizer = SelfSizingHeightStabilizer()
  private var selfSizingTraitSignature: SelfSizingTraitSignature?
  private var collectionWidth: CGFloat = 0
  private var theme: IOSThemeSnapshot?
  private var messageViewImplementation: MessageViewImplementation = .legacy
  private var pendingV2Snapshot: PendingV2Snapshot?
  private var v2SnapshotDisplayLink: CADisplayLink?

  // MARK: - Props

  var isThread: Bool = false
  var outgoing: Bool = false
  var firstInGroup: Bool = true
  var lastInGroup: Bool = true
  var message: FullMessage!
  var spaceId: Int64?
  var displayMode: MessageDisplayMode = .normal

  private var usesThreadLayout: Bool {
    isThread || displayMode == .threadAnchor
  }

  private var usesAvatarOverlay: Bool {
    MessageAvatarOverlayConfig.enabled && usesThreadLayout && displayMode != .threadAnchor
  }

  private var isServiceMessage: Bool {
    message?.message.isServiceMessage == true
  }

  var canShowAvatarOverlay: Bool {
    guard let message else { return false }
    return usesAvatarOverlay && !isServiceMessage && !outgoing && message.senderInfo != nil
  }

  var avatarOverlayUserInfo: UserInfo? {
    guard canShowAvatarOverlay, let message else { return nil }
    return message.senderInfo
  }

  // MARK: - Sizes

  private let avatarSize: CGFloat = 28
  private let avatarLeading: CGFloat = 0
  private let nameLabelLeading: CGFloat = 9
  private let nameLabelTop: CGFloat = 9
  private let nameLabelHeight: CGFloat = 16
  private let horizontalPadding = MessageCollectionViewCell.sendAnimationHorizontalPadding

  // MARK: - Views

  private lazy var replyIndicator = {
    let view = ReplyIndicatorView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isHidden = true
    view.alpha = 0
    return view
  }()

  private lazy var nameLabel: UILabel = {
    var label = UILabel()
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = .secondaryLabel
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private var messageActionsButton: UIButton?

  private func makeMessageActionsButton() -> UIButton {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(
      pointSize: 17, weight: .medium
    )), for: .normal)
    button.tintColor = .secondaryLabel
    button.accessibilityLabel = "Message actions"
    button.accessibilityIdentifier = "messageActions"
    button.showsMenuAsPrimaryAction = true
    // Resolve both the cell's current identity and the menu state on each open;
    // reused cells and updates while the menu is closed must not keep old actions.
    button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
      guard let self, let provider = messageActionsMenuProvider else {
        completion([])
        return
      }
      completion(provider(self).children)
    }])
    button.isHidden = true
    contentView.addSubview(button)
    return button
  }

  var usesCustomHoldAction: Bool {
    messageHoldAction != .reactionsMenu && messageHoldAction != .none
      && displayMode != .threadAnchor && message?.canReply == true
  }

  func updateMessageHoldAction(_ action: MessageGestureAction) {
    messageHoldAction = action
    setNeedsLayout()
  }

  func isMessageActionsButton(at point: CGPoint) -> Bool {
    guard let button = messageActionsButton, !button.isHidden else { return false }
    return button.bounds.contains(button.convert(point, from: self))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard allowsMessageActions, usesCustomHoldAction, messageActionsMenuProvider != nil, let messageView else {
      messageActionsButton?.isHidden = true
      return
    }
    let button = messageActionsButton ?? makeMessageActionsButton()
    messageActionsButton = button

    // Use the empty side of the row so both renderers and media bubbles retain
    // their existing geometry. Keep a 44pt target wherever the gutter permits.
    let bubble = messageView.bubbleView.convert(messageView.bubbleView.bounds, to: contentView)
    let gutterWidth = outgoing ? bubble.minX : contentView.bounds.width - bubble.maxX
    let width = min(44, max(0, gutterWidth))
    let height = min(44, contentView.bounds.height)
    button.frame = CGRect(
      x: outgoing ? bubble.minX - width : bubble.maxX,
      y: min(max(0, bubble.maxY - height), max(0, contentView.bounds.height - height)),
      width: width,
      height: height
    )
    button.isHidden = false
    contentView.bringSubviewToFront(button)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupContentSize()
    setupSwipeGestures()
    setupReplyIndicator()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    with message: FullMessage,
    firstInGroup: Bool,
    lastInGroup: Bool,
    spaceId: Int64?,
    collectionWidth: CGFloat,
    displayMode: MessageDisplayMode = .normal,
    animateTail: Bool = true,
    theme: IOSThemeSnapshot,
    initialMetadataStatus: MessageSendingStatus? = nil,
    messageViewImplementation: MessageViewImplementation = .legacy
  ) {
    let newOutgoing = message.message.out == true
    var animatedReactionEmoji: String?

    if self.message?.id != message.id {
      clearHighlight()
    }

    if let currentMessage = self.message {
      if prevText == message.displayText, self.message == message,
         self.firstInGroup == firstInGroup, self.lastInGroup == lastInGroup,
         self.spaceId == spaceId, outgoing == newOutgoing, self.displayMode == displayMode,
         self.theme == theme,
         self.messageViewImplementation == messageViewImplementation,
         abs(self.collectionWidth - collectionWidth) <= 0.5
      {
        // skip only if everything is exact match including outgoing state and layout width
        if let pendingV2Snapshot, pendingV2Snapshot.message != message {
          cancelPendingV2Snapshot()
        }
        return
      }

      if isDeliveryAcknowledgementUpdate(from: currentMessage, to: message),
         abs(self.collectionWidth - collectionWidth) <= 0.5,
         firstInGroup == self.firstInGroup,
         lastInGroup == self.lastInGroup,
         spaceId == self.spaceId,
         outgoing == newOutgoing,
         displayMode == self.displayMode,
         self.theme == theme,
         self.messageViewImplementation == messageViewImplementation,
         let messageView
      {
        cancelPendingV2Snapshot()
        prevText = message.displayText
        self.message = message
        canReply = message.canReply && displayMode != .threadAnchor
        messageView.updateDeliveryAcknowledgement(to: message)
        updateSwipeAvailability()
        return
      }

      if messageViewImplementation == .legacy,
         isAcknowledgementOnlyUpdate(from: currentMessage, to: message),
         abs(self.collectionWidth - collectionWidth) <= 0.5,
         firstInGroup == self.firstInGroup,
         lastInGroup == self.lastInGroup,
         spaceId == self.spaceId,
         outgoing == newOutgoing,
         displayMode == self.displayMode,
         self.theme == theme,
         self.messageViewImplementation == .legacy,
         let messageView,
         messageView.canUpdateAcknowledgementInPlace(to: message)
      {
        cancelPendingV2Snapshot()
        prevText = message.displayText
        self.message = message
        canReply = message.canReply && displayMode != .threadAnchor
        resetSelfSizingState()
        messageView.updateAcknowledgement(to: message)
        updateSwipeAvailability()
        setNeedsLayout()
        return
      }

      if isReactionOnlyUpdate(from: currentMessage, to: message) {
        animatedReactionEmoji = changedReactionEmoji(from: currentMessage, to: message)
        if abs(self.collectionWidth - collectionWidth) <= 0.5,
           firstInGroup == self.firstInGroup,
           lastInGroup == self.lastInGroup,
           spaceId == self.spaceId,
           outgoing == newOutgoing,
           displayMode == self.displayMode,
           self.theme == theme,
           self.messageViewImplementation == messageViewImplementation,
           let messageView,
           messageView.canUpdateReactionsInPlace(to: message)
        {
          cancelPendingV2Snapshot()
          prevText = message.displayText
          self.message = message
          canReply = message.canReply && displayMode != .threadAnchor
          resetSelfSizingState()
          messageView.updateReactions(to: message, animatedEmoji: animatedReactionEmoji)
          setNeedsLayout()
          return
        }
      }

      if abs(self.collectionWidth - collectionWidth) <= 0.5,
         self.theme == theme,
         self.messageViewImplementation == messageViewImplementation,
         canUpdateBubbleTailOnly(
           with: message,
           firstInGroup: firstInGroup,
           lastInGroup: lastInGroup,
           spaceId: spaceId,
           displayMode: displayMode,
           outgoing: newOutgoing
         )
      {
        cancelPendingV2Snapshot()
        self.lastInGroup = lastInGroup
        canReply = message.canReply && displayMode != .threadAnchor
        messageView?.updateBubbleTail(side: bubbleTailSide, animated: animateTail)
        updateSwipeAvailability()
        return
      }

      if messageViewImplementation == .v2,
         self.messageViewImplementation == .v2,
         abs(self.collectionWidth - collectionWidth) <= 0.5,
         firstInGroup == self.firstInGroup,
         lastInGroup == self.lastInGroup,
         spaceId == self.spaceId,
         outgoing == newOutgoing,
         displayMode == self.displayMode,
         self.theme == theme,
         let nextView = messageView as? UIMessageView2,
         nextView.canApplySnapshot(message)
      {
        if isHighFrequencyTextUpdate(from: currentMessage, to: message) {
          enqueueV2Snapshot(message, animatedReactionEmoji: animatedReactionEmoji)
          return
        }
        cancelPendingV2Snapshot()
        prevText = message.displayText
        self.message = message
        canReply = message.canReply && displayMode != .threadAnchor
        resetSelfSizingState()
        nextView.applySnapshot(message, animatedReactionEmoji: animatedReactionEmoji)
        updateSwipeAvailability()
        setNeedsLayout()
        return
      }
    }

    cancelPendingV2Snapshot()
    resetSelfSizingState()

    // update it first
    prevText = message.displayText
    self.message = message
    self.firstInGroup = firstInGroup
    self.lastInGroup = lastInGroup
    self.spaceId = spaceId
    self.collectionWidth = collectionWidth
    self.displayMode = displayMode
    self.theme = theme
    self.messageViewImplementation = messageViewImplementation
    isThread = message.peerId.isThread
    outgoing = newOutgoing
    canReply = message.canReply && displayMode != .threadAnchor

    resetCell()

    nameLabel.text = message.from?.firstName ?? "USER"

    setupThreadHeaderViewsIfNeeded()
    setupBaseMessageConstraints(
      animatedReactionEmoji: animatedReactionEmoji,
      initialMetadataStatus: initialMetadataStatus
    )

    contentView.transform = Self.contentTransform

    // Enable/disable swipe based on message state
    updateSwipeAvailability()
  }

  func prepareInsertionAnimation() {
    isPreparedForSendAnimationTarget = false
    alpha = 0
    contentView.alpha = 1
    contentView.transform = Self.insertionContentTransform
  }

  func animateInsertion() {
    let insertingMessageView = messageView
    UIView.animate(
      withDuration: 0.2,
      delay: 0,
      usingSpringWithDamping: 0.94,
      initialSpringVelocity: 0.7,
      options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      self.alpha = 1
      self.contentView.alpha = 1
      self.contentView.transform = Self.contentTransform
    } completion: { _ in
      insertingMessageView?.animateInitialDeliveryAcknowledgementIfNeeded()
    }
  }

  func prepareSendAnimationTarget() {
    setSendAnimationTargetPrepared(true)
  }

  func revealSendAnimationTarget() {
    // Ordinary diffable reconfiguration also calls this method. Only a prepared
    // send target needs recursive cleanup; clearing an already-visible cell
    // cancels unrelated bubble and neighboring-row geometry animations.
    if messageViewImplementation == .legacy || isPreparedForSendAnimationTarget {
      setSendAnimationTargetPrepared(false)
    }
    messageView?.animateInitialDeliveryAcknowledgementIfNeeded()
  }

  private func setSendAnimationTargetPrepared(_ prepared: Bool) {
    SendMessageAnimationActions.performWithoutAnimation {
      clearSendAnimationTargetLayerAnimations()
      isPreparedForSendAnimationTarget = prepared
      alpha = 1
      contentView.alpha = prepared ? 0 : 1
      contentView.transform = Self.contentTransform
      setNeedsLayout()
      layoutIfNeeded()
      contentView.layoutIfNeeded()
      messageView?.layoutIfNeeded()
    }
  }

  func sendAnimationTargetPresentationInWindow() -> SendMessageAnimationTargetPresentation? {
    snapshotSendAnimationTargetWithStableVisibleContent {
      guard let messageView else { return nil }

      return withSendAnimationFittedTargetLayout { geometry in
        let bubbleSnapshotView = SendMessageAnimationTargetSnapshotting.makeSnapshot(
          from: messageView.bubbleView,
          side: bubbleTailSide
        )
        guard let bubbleSnapshotView else {
          return nil
        }
        bubbleSnapshotView.frame = CGRect(
          origin: .zero,
          size: geometry.bubbleFrame.size
        )
        bubbleSnapshotView.backgroundColor = .clear
        bubbleSnapshotView.isOpaque = false
        bubbleSnapshotView.clipsToBounds = false
        bubbleSnapshotView.isUserInteractionEnabled = false

        return SendMessageAnimationTargetPresentation(
          cellFrame: geometry.cellFrame,
          bubbleFrame: geometry.bubbleFrame,
          textFrame: geometry.textFrame,
          bubbleSnapshotView: bubbleSnapshotView,
          textFrameInBubble: geometry.textFrameInBubble,
          textFirstBaselineYInWindow: geometry.textFirstBaselineYInWindow,
          textFirstBaselineYInBubble: geometry.textFirstBaselineYInBubble
        )
      }
    }
  }

  private func withSendAnimationFittedTargetLayout<T>(
    _ body: (SendMessageAnimationTargetGeometry) -> T?
  ) -> T? {
    guard let window, bounds.width > 0, bounds.height > 0 else {
      return sendAnimationTargetGeometryInWindow().flatMap(body)
    }

    let originalBounds = bounds
    let fittedHeight = sendAnimationFittedTargetHeight()
    let shouldUseFittedHeight = fittedHeight.map {
      $0.isFinite && $0 > 0 && abs($0 - originalBounds.height) > 0.25
    } ?? false

    guard shouldUseFittedHeight, let fittedHeight else {
      return sendAnimationTargetGeometryInWindow().flatMap(body)
    }

    let bottomAlignedWindowOffsetY = originalBounds.height - fittedHeight
    SendMessageAnimationActions.performWithoutAnimation {
      bounds = CGRect(
        origin: originalBounds.origin,
        size: CGSize(width: originalBounds.width, height: fittedHeight)
      )
      setNeedsLayout()
      layoutIfNeeded()
      contentView.layoutIfNeeded()
      messageView?.layoutIfNeeded()
      messageView?.bubbleView.layoutIfNeeded()
      messageView?.sendAnimationTextView().layoutIfNeeded()
    }

    defer {
      SendMessageAnimationActions.performWithoutAnimation {
        bounds = originalBounds
        setNeedsLayout()
        layoutIfNeeded()
        contentView.layoutIfNeeded()
        messageView?.layoutIfNeeded()
      }
    }

    guard let geometry = sendAnimationTargetGeometryInWindow() else {
      return nil
    }

    let adjustedGeometry = geometry.offsetInWindowBy(y: bottomAlignedWindowOffsetY)
    SendMessageAnimationDiagnostics.debug(
      "target fitted-layout stable=\(message?.id.description ?? "nil") currentH=\(String(format: "%.1f", originalBounds.height)) fittedH=\(String(format: "%.1f", fittedHeight)) bottomAlignDy=\(String(format: "%.1f", bottomAlignedWindowOffsetY)) rawBubble=[\(SendMessageAnimationDiagnostics.rect(geometry.bubbleFrame))] adjustedBubble=[\(SendMessageAnimationDiagnostics.rect(adjustedGeometry.bubbleFrame))] window=\(window.bounds.isFiniteAndVisible)"
    )
    return body(adjustedGeometry)
  }

  private func sendAnimationFittedTargetHeight() -> CGFloat? {
    guard bounds.width > 0 else { return nil }

    layoutIfNeeded()
    contentView.layoutIfNeeded()

    let targetSize = CGSize(
      width: bounds.width,
      height: UIView.layoutFittingCompressedSize.height
    )
    let size = contentView.systemLayoutSizeFitting(
      targetSize,
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    guard size.height.isFinite, size.height > 0 else { return nil }
    return size.height
  }

  func stabilizeSendAnimationTargetForSnapshot() {
    SendMessageAnimationActions.performWithoutAnimation {
      clearSendAnimationTargetLayerAnimations()
      alpha = 1
      contentView.transform = Self.contentTransform
      setNeedsLayout()
      layoutIfNeeded()
      contentView.layoutIfNeeded()
      messageView?.layoutIfNeeded()
      messageView?.bubbleView.layoutIfNeeded()
      messageView?.sendAnimationTextView().layoutIfNeeded()
      clearSendAnimationTargetLayerAnimations()
    }
  }

  private func snapshotSendAnimationTargetWithStableVisibleContent<T>(_ body: () -> T) -> T {
    let previousCellAlpha = alpha
    let previousAlpha = contentView.alpha
    let previousHidden = contentView.isHidden
    let previousTransform = contentView.transform
    let previousMessageAlpha = messageView?.alpha
    let previousMessageHidden = messageView?.isHidden
    let animationCountBefore = sendAnimationLayerAnimationCount(in: self)
    SendMessageAnimationDiagnostics.debug(
      "target snapshot-stabilize stable=\(message?.id.description ?? "nil") prepared=\(isPreparedForSendAnimationTarget) cellAlpha=\(String(format: "%.2f", previousCellAlpha)) contentAlpha=\(String(format: "%.2f", previousAlpha)) contentHidden=\(previousHidden) animationsBefore=\(animationCountBefore) animationsEnabled=\(UIView.areAnimationsEnabled) inheritedDuration=\(String(format: "%.3f", UIView.inheritedAnimationDuration))"
    )

    SendMessageAnimationActions.performWithoutAnimation {
      clearSendAnimationTargetLayerAnimations()
      alpha = 1
      contentView.alpha = 1
      contentView.isHidden = false
      contentView.transform = Self.contentTransform
      messageView?.alpha = 1
      messageView?.isHidden = false
      setNeedsLayout()
      layoutIfNeeded()
      contentView.layoutIfNeeded()
      messageView?.layoutIfNeeded()
      messageView?.bubbleView.layoutIfNeeded()
      messageView?.sendAnimationTextView().layoutIfNeeded()
      clearSendAnimationTargetLayerAnimations()
    }

    defer {
      SendMessageAnimationActions.performWithoutAnimation {
        clearSendAnimationTargetLayerAnimations()
        alpha = previousCellAlpha
        contentView.alpha = previousAlpha
        contentView.isHidden = previousHidden
        contentView.transform = previousTransform
        if let previousMessageAlpha {
          messageView?.alpha = previousMessageAlpha
        }
        if let previousMessageHidden {
          messageView?.isHidden = previousMessageHidden
        }
        setNeedsLayout()
        layoutIfNeeded()
        contentView.layoutIfNeeded()
        clearSendAnimationTargetLayerAnimations()
      }
      let animationCountAfter = sendAnimationLayerAnimationCount(in: self)
      SendMessageAnimationDiagnostics.debug(
        "target snapshot-restore stable=\(message?.id.description ?? "nil") contentAlpha=\(String(format: "%.2f", contentView.alpha)) animationsAfter=\(animationCountAfter)"
      )
    }

    return SendMessageAnimationActions.performWithoutAnimation {
      body()
    }
  }

  private func sendAnimationLayerAnimationCount(in view: UIView) -> Int {
    var count = view.layer.animationKeys()?.count ?? 0
    for subview in view.subviews {
      count += sendAnimationLayerAnimationCount(in: subview)
    }
    return count
  }

  private func clearSendAnimationTargetLayerAnimations() {
    SendMessageAnimationActions.removeAnimationsRecursively(from: self)
  }

  func sendAnimationTargetGeometryInWindow() -> SendMessageAnimationTargetGeometry? {
    layoutIfNeeded()
    contentView.layoutIfNeeded()

    guard let window, let messageView else { return nil }

    messageView.layoutIfNeeded()
    messageView.bubbleView.layoutIfNeeded()
    let textView = messageView.sendAnimationTextView()
    textView.layoutIfNeeded()

    let cellFrame = convert(bounds, to: window)
    let bubbleFrame = messageView.bubbleView.convert(messageView.bubbleView.bounds, to: window)
    let textGeometry = textView.sendAnimationTextFrame()
    let textFrameInLabel = textGeometry?.visibleTextFrame
    let textFrame = textGeometry.map {
      textView.convert($0.visibleTextFrame, to: window)
    }
    let textFrameInBubble = textGeometry.map {
      textView.convert($0.visibleTextFrame, to: messageView.bubbleView)
    }
    let textFirstBaselineYInWindow = textGeometry.map {
      textView.convert(CGPoint(x: 0, y: $0.firstBaselineY), to: window).y
    }
    let textFirstBaselineYInBubble = textGeometry.map {
      textView.convert(CGPoint(x: 0, y: $0.firstBaselineY), to: messageView.bubbleView).y
    }

    guard cellFrame.isFiniteAndVisible,
          bubbleFrame.isFiniteAndVisible,
          let textFrameInLabel,
          let textFrame,
          let textFrameInBubble,
          let textFirstBaselineYInWindow,
          let textFirstBaselineYInBubble,
          textFrameInLabel.isFiniteAndVisible,
          textFrame.isFiniteAndVisible,
          textFrameInBubble.isFiniteAndVisible,
          textFirstBaselineYInWindow.isFinite,
          textFirstBaselineYInBubble.isFinite
    else {
      SendMessageAnimationDiagnostics.event(
        "target cell-geometry-unavailable stable=\(message?.id.description ?? "nil") cell=[\(SendMessageAnimationDiagnostics.rect(cellFrame))] bubble=[\(SendMessageAnimationDiagnostics.rect(bubbleFrame))] text=\(textFrame.map { "[\(SendMessageAnimationDiagnostics.rect($0))]" } ?? "nil") textInLabel=\(textFrameInLabel.map { "[\(SendMessageAnimationDiagnostics.rect($0))]" } ?? "nil") textInBubble=\(textFrameInBubble.map { "[\(SendMessageAnimationDiagnostics.rect($0))]" } ?? "nil") baselineY=\(textFirstBaselineYInWindow.map { String(format: "%.1f", $0) } ?? "nil") baselineBubbleY=\(textFirstBaselineYInBubble.map { String(format: "%.1f", $0) } ?? "nil") preparedTarget=\(isPreparedForSendAnimationTarget)"
      )
      return nil
    }

    return SendMessageAnimationTargetGeometry(
      cellFrame: cellFrame,
      bubbleFrame: bubbleFrame,
      textFrame: textFrame,
      textFrameInBubble: textFrameInBubble,
      textFrameInLabel: textFrameInLabel,
      textFirstBaselineYInWindow: textFirstBaselineYInWindow,
      textFirstBaselineYInBubble: textFirstBaselineYInBubble
    )
  }

  func bubbleTailSideForSendAnimation() -> MessageBubbleTailSide {
    bubbleTailSide
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    isContextMenuSourceHidden = false
    if messageViewImplementation == .v2 {
      cancelPendingV2Snapshot()
      layer.removeAllAnimations()
      contentView.layer.removeAllAnimations()
      transform = .identity
    }

    alpha = 1
    contentView.alpha = 1
    contentView.transform = Self.contentTransform
    isPreparedForSendAnimationTarget = false

    resetCell()
    panGesture?.isEnabled = true
    canReply = true
    displayMode = .normal
    isThread = false
    outgoing = false
    collectionWidth = 0
    firstInGroup = true
    lastInGroup = true

    // Clear cached values to force reconfiguration
    prevText = nil
    message = nil
    theme = nil
    messageViewImplementation = .legacy
    resetSelfSizingState()

    // Reset delegate
    delegate = nil
    onPhotoTap = nil
    onReactionsMenu = nil
    messageActionsMenuProvider = nil
    allowsMessageActions = false
    messageActionsButton?.isHidden = true
    grabOverlappingAvatar = nil
    onV2GeometryChange = nil
  }

  // MARK: - Constraints

  var replyViewCenterYConstraint: NSLayoutConstraint!
  private var replyIndicatorLeftCenterConstraint: NSLayoutConstraint?
  private var replyIndicatorRightCenterConstraint: NSLayoutConstraint?

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    guard
      let attributes = layoutAttributes.copy() as? UICollectionViewLayoutAttributes,
      layoutAttributes.bounds.width.isFinite,
      layoutAttributes.bounds.width > 0
    else {
      return layoutAttributes
    }

    setNeedsLayout()
    layoutIfNeeded()

    let targetSize = CGSize(
      width: layoutAttributes.bounds.width,
      height: UIView.layoutFittingCompressedSize.height
    )

    let size = contentView.systemLayoutSizeFitting(
      targetSize,
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )

    guard size.height.isFinite, size.height > 0 else {
      return layoutAttributes
    }

    let displayScale = max(traitCollection.displayScale, 1)
    if messageViewImplementation == .v2 {
      var fittedFrame = layoutAttributes.frame
      fittedFrame.size.height = ceil(size.height * displayScale) / displayScale
      attributes.frame = fittedFrame
      return attributes
    }

    let traitSignature = SelfSizingTraitSignature(
      contentSizeCategory: traitCollection.preferredContentSizeCategory,
      displayScale: displayScale,
      layoutDirection: traitCollection.layoutDirection
    )
    if selfSizingTraitSignature != traitSignature {
      selfSizingHeightStabilizer.reset()
      selfSizingTraitSignature = traitSignature
    }

    let measuredHeight = ceil(size.height * displayScale) / displayScale
    let stabilization = selfSizingHeightStabilizer.resolve(
      width: targetSize.width,
      measuredHeight: measuredHeight,
      heightTolerance: 0.5 / displayScale
    )
    let fittedHeight = stabilization.height
    if let instability = stabilization.instability {
      reportUnstableSelfSizing(instability, width: targetSize.width)
    }

    // The compositional layout owns the item width. Returning Auto Layout's width here can
    // cause the collection view to alternate between its fractional width and the fitted width.
    var fittedFrame = layoutAttributes.frame
    fittedFrame.size.height = fittedHeight
    attributes.frame = fittedFrame
    return attributes
  }

  private func resetSelfSizingState() {
    selfSizingHeightStabilizer.reset()
    selfSizingTraitSignature = nil
  }

  private func reportUnstableSelfSizing(
    _ instability: SelfSizingHeightStabilizer.Instability,
    width: CGFloat
  ) {
    guard let message else { return }

    let largeURLPreviewCount = message.attachments.count { attachment in
      guard let preview = attachment.urlPreview else { return false }
      return URLPreviewView.preferredMode(for: preview, photoInfo: attachment.photoInfo) == .large
    }
    PerformanceTrace.breadcrumb(
      "unstable iOS message cell self-sizing",
      category: "messages.layout",
      level: .warning,
      data: [
        "chat_id": String(message.message.chatId),
        "message_id": String(message.message.messageId),
        "peer": message.peerId.toString(),
        "message_kind": isServiceMessage ? "service" : "regular",
        "display_mode": String(describing: displayMode),
        "fitting_width": Double(width),
        "previous_height": Double(instability.previousHeight),
        "fitted_height": Double(instability.measuredHeight),
        "measured_height": Double(instability.measuredHeight),
        "stabilized_height": Double(instability.stabilizedHeight),
        "attachment_count": message.attachments.count,
        "large_url_preview_count": largeURLPreviewCount,
        "reaction_count": message.reactions.count,
      ]
    )
  }

  @objc func handleAvatarTap() {
    guard let from = message?.from else { return }
    onUserTap?(from.id)
  }

  func highlightBubble() {
    guard let messageView else { return }
    guard !isServiceMessage else { return }
    let highlightColor = messageView.outgoing
      ? (theme?.outgoingBubble.uiColor ?? .systemBlue).lighten(by: 0.3)
      : (theme?.primary.uiColor ?? .systemBlue).withAlphaComponent(0.4)
    messageView.bubbleView.highlight(color: highlightColor)
    messageView.highlightMediaOverlay()
  }

  func clearHighlight() {
    guard let messageView else { return }
    guard !isServiceMessage else { return }
    messageView.bubbleView.clearHighlight()
    messageView.clearMediaHighlight()
  }
}

extension MessageCollectionViewCell {
  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer == panGesture else { return true }

    guard !isMessageActionsButton(at: gestureRecognizer.location(in: self)) else { return false }

    // Do not begin swipe-to-reply if replying is not allowed
    if !canReply { return false }

    let velocity = panGesture.velocity(in: contentView)

    if let nextView = messageView as? UIMessageView2 {
      let point = panGesture.location(in: nextView)
      if nextView.containsHorizontalScroller(at: point), abs(velocity.x) > abs(velocity.y) {
        return false
      }
    }

    // Calculate angle and only allow nearly horizontal swipes
    // An 16 degree angle corresponds to tan(16°) ≈ 0.287
    // This means vertical component should be at most 0.287 times the horizontal component
    // let maxAngleTangent: CGFloat = 0.287 // tan(16°)
    let maxAngleTangent: CGFloat = 0.4452286853 // tan(24°)
    let isHorizontalEnough = abs(velocity.y) <= abs(velocity.x) * maxAngleTangent

    guard abs(velocity.x) > abs(velocity.y), isHorizontalEnough else { return false }

    let direction = INUserSettings.current.messageGestures.swipeToReplyDirection
    guard direction.accepts(velocity.x) else { return false }

    return true
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    return false
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    guard gestureRecognizer == panGesture else { return false }
    guard otherGestureRecognizer is UIScreenEdgePanGestureRecognizer else { return false }

    // A configured reply swipe on a replyable message exclusively owns the
    // touch. The system back gesture can proceed only if this pan is rejected.
    return true
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    // Ignore pan if cannot reply
    guard canReply else {
      resetSwipeState()
      return
    }
    let translation = gesture.translation(in: contentView)
    let velocity = gesture.velocity(in: contentView)

    switch gesture.state {
      case .began:
        swipeDirection = INUserSettings.current.messageGestures.swipeToReplyDirection
        swipedAvatarOverlayView?.transform = .identity
        swipedAvatarOverlayView = grabOverlappingAvatar?(contentView)
        initialTranslation = translation.x
        replyIndicator.isHidden = false
        replyIndicator.alpha = 1
        replyIndicator.reset()
        updateReplyIndicatorPosition()
      case .changed:
        handleSwipeProgress(translation: translation, velocity: velocity)
      case .ended, .cancelled:
        finalizeSwipe(translation: translation, velocity: velocity)
      default:
        resetSwipeState()
    }
  }

  private func handleSwipeProgress(translation: CGPoint, velocity: CGPoint) {
    let adjustedTranslation = translation.x - initialTranslation
    guard swipeDirection.accepts(adjustedTranslation) else {
      resetSwipeState(releaseAvatar: false)
      return
    }

    let maxTranslation: CGFloat = 80
    let progress = min(abs(adjustedTranslation) / maxTranslation, 1)
    let boundedTranslation = swipeDirection.horizontalSign * maxTranslation * progress

    messageView?.transform = CGAffineTransform(translationX: boundedTranslation, y: 0)
    nameLabel.transform = CGAffineTransform(translationX: boundedTranslation, y: 0)
    avatarView?.transform = CGAffineTransform(translationX: boundedTranslation, y: 0)
    swipedAvatarOverlayView?.transform = CGAffineTransform(
      translationX: boundedTranslation,
      y: 0
    )

    replyIndicator.isHidden = false
    replyIndicator.updateProgress(progress)

    if progress > 0.7 {
      // Play haptic feedback when swipe crosses the activation threshold
      if !swipeActive {
        let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
        feedbackGenerator.prepare()
        feedbackGenerator.impactOccurred()
      }
      swipeActive = true
    } else {
      swipeActive = false
    }
  }

  private func finalizeSwipe(translation: CGPoint, velocity: CGPoint) {
    let adjustedTranslation = translation.x - initialTranslation
    guard swipeDirection.accepts(adjustedTranslation) else {
      UIView.animate(withDuration: 0.4) {
        self.messageView?.transform = .identity
        self.nameLabel.transform = .identity
        self.avatarView?.transform = .identity
        self.swipedAvatarOverlayView?.transform = .identity
      }
      resetSwipeState()
      return
    }

    let progress = min(abs(adjustedTranslation) / 80, 1)
    let shouldTrigger = progress > 0.7 || abs(velocity.x) > 600

    if shouldTrigger {
      ChatState.shared.setReplyingMessageId(peer: message.message.peerId, id: message.message.messageId)
    }

    UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
      self.messageView?.transform = .identity
      self.nameLabel.transform = .identity
      self.avatarView?.transform = .identity
      self.swipedAvatarOverlayView?.transform = .identity
      self.replyIndicator.alpha = 0
    } completion: { _ in
      if shouldTrigger {
        self.delegate?.didSwipeToReply(for: self.message)
      }
      self.resetSwipeState()
    }
  }

  private func resetSwipeState(releaseAvatar: Bool = true) {
    replyIndicator.isHidden = true
    replyIndicator.alpha = 1
    replyIndicator.reset()
    initialTranslation = 0
    swipeActive = false

    messageView?.transform = .identity
    nameLabel.transform = .identity
    avatarView?.transform = .identity
    swipedAvatarOverlayView?.transform = .identity
    if releaseAvatar {
      swipedAvatarOverlayView = nil
    }
  }

  func setupReplyIndicator() {
    contentView.addSubview(replyIndicator)

    replyViewCenterYConstraint = replyIndicator.centerYAnchor
      .constraint(equalTo: contentView.centerYAnchor, constant: topBubblePadding / 2)

    NSLayoutConstraint.activate(
      [
        replyViewCenterYConstraint,
        replyIndicator.widthAnchor.constraint(equalToConstant: 40),
        replyIndicator.heightAnchor.constraint(equalToConstant: 40),
      ]
    )

    replyIndicatorLeftCenterConstraint = replyIndicator.centerXAnchor.constraint(
      equalTo: contentView.leftAnchor,
      constant: Self.replyIndicatorSideCenterInset
    )
    replyIndicatorRightCenterConstraint = replyIndicator.centerXAnchor.constraint(
      equalTo: contentView.rightAnchor,
      constant: -Self.replyIndicatorSideCenterInset
    )
    updateReplyIndicatorPosition()
  }

  private func updateReplyIndicatorPosition() {
    replyIndicatorLeftCenterConstraint?.isActive = swipeDirection.revealsLeftEdge
    replyIndicatorRightCenterConstraint?.isActive = !swipeDirection.revealsLeftEdge
  }

  func setupSwipeGestures() {
    panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    panGesture.delegate = self
    contentView.addGestureRecognizer(panGesture)
  }

  private func updateSwipeAvailability() {
    panGesture?.isEnabled = canReply
    if !canReply {
      // Ensure UI is reset when swipe is disabled
      resetSwipeState()
    }
  }

  func setupContentSize() {
    contentView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    contentView.setContentHuggingPriority(.defaultLow, for: .horizontal)
  }

  func setupThreadHeaderViewsIfNeeded() {
    guard let message, !isServiceMessage else { return }
    guard usesThreadLayout, !outgoing else { return }

    let avatarOrSpacer: UIView
    if showsCellAvatar, let from = message.senderInfo {
      let avatar = UserAvatarView()
      UIView.performWithoutAnimation {
        avatar.configure(with: from, size: avatarSize)
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatarView = avatar
      }

      let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleAvatarTap))
      avatar.isUserInteractionEnabled = true
      avatar.addGestureRecognizer(tapGesture)
      avatarOrSpacer = avatar

    } else {
      let spacer = UIView()
      spacer.translatesAutoresizingMaskIntoConstraints = false
      avatarOrSpacer = spacer
    }
    avatarSpacerView = avatarOrSpacer
    contentView.addSubview(avatarOrSpacer)

    var avatarConstraints = [
      avatarOrSpacer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
      avatarOrSpacer.leadingAnchor.constraint(
        equalTo: contentView.leadingAnchor,
        constant: avatarLeading + horizontalPadding
      ),
      avatarOrSpacer.widthAnchor.constraint(equalToConstant: avatarSize),
      avatarOrSpacer.heightAnchor.constraint(equalToConstant: avatarSize),
    ]
    if showsCellAvatar {
      avatarConstraints[0] = avatarOrSpacer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
    }
    NSLayoutConstraint.activate(avatarConstraints)

    if firstInGroup {
      contentView.addSubview(nameLabel)
      NSLayoutConstraint.activate([
        nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: nameLabelTop),
        nameLabel.heightAnchor.constraint(equalToConstant: nameLabelHeight),
        nameLabel.leadingAnchor.constraint(equalTo: avatarOrSpacer.trailingAnchor, constant: nameLabelLeading),
      ])
    }
  }

  /// Space between bubble's top to contentView's top (includes name height)
  private var topBubblePadding: CGFloat {
    if isServiceMessage {
      return 0
    }

    if usesThreadLayout, firstInGroup, !outgoing {
      return nameLabelHeight + nameLabelTop
    } else {
      return firstInGroup ? 6 : 1
    }
  }

  private var bubbleTailSide: MessageBubbleTailSide {
    guard message != nil, !isServiceMessage else { return .none }
    guard lastInGroup else { return .none }
    return outgoing ? .trailing : .leading
  }

  private var showsCellAvatar: Bool {
    guard let message else { return false }
    return showsInlineAvatar(
      for: message,
      outgoing: outgoing,
      lastInGroup: lastInGroup,
      displayMode: displayMode
    )
  }

  private func usesThreadLayout(for message: FullMessage, displayMode: MessageDisplayMode) -> Bool {
    message.peerId.isThread || displayMode == .threadAnchor
  }

  private func usesAvatarOverlay(for message: FullMessage, displayMode: MessageDisplayMode) -> Bool {
    MessageAvatarOverlayConfig.enabled &&
      usesThreadLayout(for: message, displayMode: displayMode) &&
      displayMode != .threadAnchor
  }

  private func showsInlineAvatar(
    for message: FullMessage,
    outgoing: Bool,
    lastInGroup: Bool,
    displayMode: MessageDisplayMode
  ) -> Bool {
    usesThreadLayout(for: message, displayMode: displayMode) &&
      !message.message.isServiceMessage &&
      !outgoing &&
      lastInGroup &&
      message.senderInfo != nil &&
      !usesAvatarOverlay(for: message, displayMode: displayMode)
  }

  private func canUpdateBubbleTailOnly(
    with newMessage: FullMessage,
    firstInGroup newFirstInGroup: Bool,
    lastInGroup newLastInGroup: Bool,
    spaceId newSpaceId: Int64?,
    displayMode newDisplayMode: MessageDisplayMode,
    outgoing newOutgoing: Bool
  ) -> Bool {
    guard let currentMessage = message, messageView != nil else { return false }
    guard !currentMessage.message.isServiceMessage, !newMessage.message.isServiceMessage else {
      return false
    }
    guard prevText == newMessage.displayText, currentMessage == newMessage else { return false }
    guard firstInGroup == newFirstInGroup, lastInGroup != newLastInGroup else { return false }
    guard spaceId == newSpaceId, outgoing == newOutgoing, displayMode == newDisplayMode else {
      return false
    }

    let oldShowsAvatar = showsInlineAvatar(
      for: currentMessage,
      outgoing: outgoing,
      lastInGroup: lastInGroup,
      displayMode: displayMode
    )
    let newShowsAvatar = showsInlineAvatar(
      for: newMessage,
      outgoing: newOutgoing,
      lastInGroup: newLastInGroup,
      displayMode: newDisplayMode
    )
    return oldShowsAvatar == newShowsAvatar
  }

  private func isReactionOnlyUpdate(from currentMessage: FullMessage, to newMessage: FullMessage) -> Bool {
    guard currentMessage.reactions != newMessage.reactions else { return false }

    var currentWithoutReactions = currentMessage
    currentWithoutReactions.reactions = []
    var newWithoutReactions = newMessage
    newWithoutReactions.reactions = []
    return currentWithoutReactions == newWithoutReactions
  }

  private func isAcknowledgementOnlyUpdate(
    from currentMessage: FullMessage,
    to newMessage: FullMessage
  ) -> Bool {
    guard currentMessage.acknowledgements != newMessage.acknowledgements
      || currentMessage.currentUserAcknowledgement != newMessage.currentUserAcknowledgement
    else { return false }
    return currentMessage.withoutAcknowledgements == newMessage.withoutAcknowledgements
  }

  private func isDeliveryAcknowledgementUpdate(
    from currentMessage: FullMessage,
    to newMessage: FullMessage
  ) -> Bool {
    guard currentMessage.id == newMessage.id,
          currentMessage.message.status == .sending,
          newMessage.message.status == .sent
    else { return false }

    var acknowledgedCurrentMessage = currentMessage
    acknowledgedCurrentMessage.message.status = newMessage.message.status
    acknowledgedCurrentMessage.message.messageId = newMessage.message.messageId
    acknowledgedCurrentMessage.message.randomId = newMessage.message.randomId
    return acknowledgedCurrentMessage == newMessage
  }

  private func changedReactionEmoji(from currentMessage: FullMessage, to newMessage: FullMessage) -> String? {
    let currentByEmoji = Dictionary(grouping: currentMessage.reactions) { $0.reaction.emoji }
    let newByEmoji = Dictionary(grouping: newMessage.reactions) { $0.reaction.emoji }
    var candidates: [String] = []

    for emoji in newMessage.groupedReactions.map(\.emoji) + currentMessage.groupedReactions.map(\.emoji)
      where !candidates.contains(emoji)
    {
      candidates.append(emoji)
    }

    return candidates.first { currentByEmoji[$0] != newByEmoji[$0] }
  }

  func avatarOverlayFrame(in view: UIView) -> CGRect? {
    guard canShowAvatarOverlay, contentView.bounds.width > 0, contentView.bounds.height > 0 else {
      return nil
    }

    let localFrame = CGRect(
      x: avatarLeading + horizontalPadding,
      y: max(0, contentView.bounds.maxY - avatarSize),
      width: avatarSize,
      height: avatarSize
    )
    return contentView.convert(localFrame, to: view)
  }

  func avatarOverlayLimitFrame(in view: UIView) -> CGRect? {
    guard canShowAvatarOverlay,
          contentView.bounds.width > 0,
          contentView.bounds.height > 0
    else {
      return nil
    }

    let bubbleTop = max(contentView.bounds.minY, topBubblePadding)
    let localFrame = CGRect(
      x: contentView.bounds.minX,
      y: bubbleTop,
      width: contentView.bounds.width,
      height: max(0, contentView.bounds.maxY - bubbleTop)
    )
    return contentView.convert(localFrame, to: view)
  }

  func setupBaseMessageConstraints(
    animatedReactionEmoji: String? = nil,
    initialMetadataStatus: MessageSendingStatus? = nil
  ) {
    guard let theme else { return }
    let newMessageView: UIMessageView
    let newMessageRootView: UIView
    switch messageViewImplementation {
      case .legacy:
        let legacyView = UIMessageView(
          fullMessage: message,
          spaceId: spaceId,
          displayMode: displayMode,
          bubbleTailSide: bubbleTailSide,
          maximumBubbleContentWidth: maximumBubbleContentWidth,
          theme: theme,
          animatedReactionEmoji: animatedReactionEmoji,
          initialMetadataStatus: initialMetadataStatus
        )
        newMessageView = legacyView
        newMessageRootView = legacyView
      case .v2:
        let nextView = UIMessageView2(
          fullMessage: message,
          spaceId: spaceId,
          displayMode: displayMode,
          bubbleTailSide: bubbleTailSide,
          maximumBubbleContentWidth: maximumBubbleContentWidth,
          theme: theme,
          animatedReactionEmoji: animatedReactionEmoji,
          initialMetadataStatus: initialMetadataStatus
        )
        nextView.onGeometryChange = { [weak self, weak nextView] oldLayout, newLayout in
          guard let self, let nextView else { return }
          let transitionGeneration = nextView.geometryTransitionGeneration
          nextView.prepareGeometryTransition(
            from: oldLayout,
            generation: transitionGeneration
          )
          resetSelfSizingState()
          setNeedsLayout()
          guard let onV2GeometryChange else {
            nextView.applyGeometryTransition(
              to: newLayout,
              generation: transitionGeneration
            )
            nextView.finishGeometryTransition(generation: transitionGeneration)
            return
          }
          onV2GeometryChange(self, oldLayout, newLayout)
        }
        newMessageView = nextView
        newMessageRootView = nextView
    }
    newMessageRootView.translatesAutoresizingMaskIntoConstraints = false
    newMessageView.onReactionsMenu = { [weak self] message in
      self?.onReactionsMenu?(message)
    }
    newMessageView.onPhotoTap = { [weak self] message, sourceView, sourceImage, url in
      self?.onPhotoTap?(message, sourceView, sourceImage, url)
    }
    contentView.addSubview(newMessageRootView)

    let topConstraint: NSLayoutConstraint
    let leadingConstraint: NSLayoutConstraint
    let trailingConstraint: NSLayoutConstraint

    // Bubble top constraint
    topConstraint = newMessageRootView.topAnchor.constraint(
      equalTo: contentView.topAnchor,
      constant: topBubblePadding
    )

    // Sync reply view
    replyViewCenterYConstraint.constant = topBubblePadding / 2

    if usesThreadLayout, !outgoing, let avatarOrSpacer = avatarSpacerView {
      leadingConstraint = newMessageRootView.leadingAnchor.constraint(
        equalTo: avatarOrSpacer.trailingAnchor,
        constant: 3
      )
      trailingConstraint = newMessageRootView.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor,
        constant: firstInGroup ? -(10 + horizontalPadding) : -horizontalPadding
      )
    } else {
      leadingConstraint = newMessageRootView.leadingAnchor.constraint(
        equalTo: contentView.leadingAnchor,
        constant: horizontalPadding
      )
      trailingConstraint = newMessageRootView.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor,
        constant: -horizontalPadding
      )
    }
    NSLayoutConstraint.activate([
      leadingConstraint,
      trailingConstraint,
      topConstraint,
      newMessageRootView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])

    messageView = newMessageView
    messageRootView = newMessageRootView
  }

  private var maximumBubbleContentWidth: CGFloat {
    let leadingInset: CGFloat
    let trailingInset: CGFloat
    if usesThreadLayout, !outgoing {
      leadingInset = horizontalPadding + avatarSize + 3
      trailingInset = firstInGroup ? 10 + horizontalPadding : horizontalPadding
    } else {
      leadingInset = horizontalPadding
      trailingInset = horizontalPadding
    }

    let messageViewWidth = max(0, collectionWidth - leadingInset - trailingInset)
    return messageViewWidth * MessageBubbleWidthPolicy.maximumWidthFraction
  }

  /// Add avatar if we have user info
  func resetCell() {
    clearHighlight()
    resetSwipeState(releaseAvatar: true)
    cancelPendingV2Snapshot()
    (messageView as? UIMessageView2)?.cancelPendingGeometryTransitions()
    messageView?.stopShineAnimation()

    messageRootView?.removeFromSuperview()
    messageRootView = nil
    messageView = nil

    nameLabel.removeFromSuperview()
    avatarView?.removeFromSuperview()
    avatarView = nil
    avatarSpacerView?.removeFromSuperview()
    avatarSpacerView = nil
  }

  private func isHighFrequencyTextUpdate(from current: FullMessage, to updated: FullMessage) -> Bool {
    current.displayText != updated.displayText
      || current.message.entities != updated.message.entities
      || current.message.blockContentPayload != updated.message.blockContentPayload
      || current.translations != updated.translations
  }

  private func enqueueV2Snapshot(_ message: FullMessage, animatedReactionEmoji: String?) {
    pendingV2Snapshot = .init(message: message, animatedReactionEmoji: animatedReactionEmoji)
    guard v2SnapshotDisplayLink == nil else { return }
    let displayLink = CADisplayLink(target: self, selector: #selector(flushPendingV2Snapshot))
    displayLink.add(to: .main, forMode: .common)
    v2SnapshotDisplayLink = displayLink
  }

  @objc private func flushPendingV2Snapshot() {
    v2SnapshotDisplayLink?.invalidate()
    v2SnapshotDisplayLink = nil
    guard let pending = pendingV2Snapshot,
          let nextView = messageView as? UIMessageView2,
          nextView.canApplySnapshot(pending.message)
    else {
      pendingV2Snapshot = nil
      return
    }
    pendingV2Snapshot = nil
    prevText = pending.message.displayText
    message = pending.message
    canReply = pending.message.canReply && displayMode != .threadAnchor
    resetSelfSizingState()
    nextView.applySnapshot(
      pending.message,
      animatedReactionEmoji: pending.animatedReactionEmoji
    )
    updateSwipeAvailability()
    setNeedsLayout()
  }

  private func cancelPendingV2Snapshot() {
    pendingV2Snapshot = nil
    v2SnapshotDisplayLink?.invalidate()
    v2SnapshotDisplayLink = nil
  }

  func applyTheme(_ theme: IOSThemeSnapshot) {
    guard self.theme != theme else { return }
    self.theme = theme
    messageView?.applyTheme(theme)
  }

  func updateContinuousBubbleGradient(in viewport: UIView) {
    messageView?.updateContinuousBubbleGradient(in: viewport)
  }
}

extension UIColor {
  func lighten(by percentage: CGFloat) -> UIColor {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
    return UIColor(
      red: min(r + (1 - r) * percentage, 1.0),
      green: min(g + (1 - g) * percentage, 1.0),
      blue: min(b + (1 - b) * percentage, 1.0),
      alpha: a
    )
  }
}
