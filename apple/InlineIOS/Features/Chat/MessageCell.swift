import InlineKit
import InlineUI
import Logger
import SwiftUI
import Translation
import UIKit

protocol MessageCellDelegate: AnyObject {
  func didSwipeToReply(for message: FullMessage)
}

class MessageCollectionViewCell: UICollectionViewCell, UIGestureRecognizerDelegate {
  static let reuseIdentifier = "MessageCell"
  static let sendAnimationHorizontalPadding: CGFloat = 8
  private static let contentTransform = CGAffineTransform(scaleX: 1, y: -1)
  private static let insertionContentTransform = contentTransform.scaledBy(x: 0.985, y: 0.985)

  var messageView: UIMessageView?
  var avatarView: UserAvatarView?
  var avatarSpacerView: UIView?

  weak var delegate: MessageCellDelegate?
  var onUserTap: ((Int64) -> Void)?
  var onPhotoTap: ((FullMessage, UIView, UIImage?, URL) -> Void)?
  private var panGesture: UIPanGestureRecognizer!
  private var swipeActive = false
  private var initialTranslation: CGFloat = 0
  private var prevText: String?
  private var canReply: Bool = true
  private(set) var isPreparedForSendAnimationTarget = false
  private var lastSelfSizingMeasurement: (width: CGFloat, height: CGFloat)?
  private var didReportUnstableSelfSizing = false

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
    displayMode: MessageDisplayMode = .normal,
    animateTail: Bool = true
  ) {
    let newOutgoing = message.message.out == true

    if self.message?.id != message.id {
      resetSelfSizingDiagnostics()
    }

    if self.message != nil {
      if prevText == message.displayText, self.message == message,
         self.firstInGroup == firstInGroup, self.lastInGroup == lastInGroup,
         self.spaceId == spaceId, outgoing == newOutgoing, self.displayMode == displayMode {
        // skip only if everything is exact match including outgoing state
        return
      }

      if canUpdateBubbleTailOnly(
        with: message,
        firstInGroup: firstInGroup,
        lastInGroup: lastInGroup,
        spaceId: spaceId,
        displayMode: displayMode,
        outgoing: newOutgoing
      ) {
        self.lastInGroup = lastInGroup
        canReply = message.canReply && displayMode != .threadAnchor
        messageView?.updateBubbleTail(side: bubbleTailSide, animated: animateTail)
        updateSwipeAvailability()
        return
      }
    }

    // update it first
    prevText = message.displayText
    self.message = message
    self.firstInGroup = firstInGroup
    self.lastInGroup = lastInGroup
    self.spaceId = spaceId
    self.displayMode = displayMode
    isThread = message.peerId.isThread
    outgoing = newOutgoing
    canReply = message.canReply && displayMode != .threadAnchor

    resetCell()

    nameLabel.text = message.from?.firstName ?? "USER"

    setupThreadHeaderViewsIfNeeded()
    setupBaseMessageConstraints()

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
    }
  }

  func prepareSendAnimationTarget() {
    setSendAnimationTargetPrepared(true)
  }

  func revealSendAnimationTarget() {
    setSendAnimationTargetPrepared(false)
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
      messageView?.messageLabel.layoutIfNeeded()
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
      messageView?.messageLabel.layoutIfNeeded()
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
      messageView?.messageLabel.layoutIfNeeded()
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
    messageView.messageLabel.layoutIfNeeded()

    let cellFrame = convert(bounds, to: window)
    let bubbleFrame = messageView.bubbleView.convert(messageView.bubbleView.bounds, to: window)
    let textGeometry = messageView.messageLabel.sendAnimationTextFrame()
    let textFrameInLabel = textGeometry?.visibleTextFrame
    let textFrame = textGeometry.map {
      messageView.messageLabel.convert($0.visibleTextFrame, to: window)
    }
    let textFrameInBubble = textGeometry.map {
      messageView.messageLabel.convert($0.visibleTextFrame, to: messageView.bubbleView)
    }
    let textFirstBaselineYInWindow = textGeometry.map {
      messageView.messageLabel.convert(CGPoint(x: 0, y: $0.firstBaselineY), to: window).y
    }
    let textFirstBaselineYInBubble = textGeometry.map {
      messageView.messageLabel.convert(CGPoint(x: 0, y: $0.firstBaselineY), to: messageView.bubbleView).y
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

    alpha = 1
    contentView.alpha = 1
    contentView.transform = Self.contentTransform
    isPreparedForSendAnimationTarget = false

    // Reset swipe state
    resetSwipeState()
    resetCell()
    panGesture?.isEnabled = true
    canReply = true
    displayMode = .normal
    isThread = false
    outgoing = false
    firstInGroup = true
    lastInGroup = true

    // Clear cached values to force reconfiguration
    prevText = nil
    message = nil
    resetSelfSizingDiagnostics()

    // Reset delegate
    delegate = nil
    onPhotoTap = nil
  }

  // MARK: - Constraints

  var replyViewCenterYConstraint: NSLayoutConstraint!

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
    let fittedHeight = ceil(size.height * displayScale) / displayScale
    reportUnstableSelfSizingIfNeeded(
      width: targetSize.width,
      height: fittedHeight
    )

    // The compositional layout owns the item width. Returning Auto Layout's width here can
    // cause the collection view to alternate between its fractional width and the fitted width.
    var fittedFrame = layoutAttributes.frame
    fittedFrame.size.height = fittedHeight
    attributes.frame = fittedFrame
    return attributes
  }

  private func resetSelfSizingDiagnostics() {
    lastSelfSizingMeasurement = nil
    didReportUnstableSelfSizing = false
  }

  private func reportUnstableSelfSizingIfNeeded(width: CGFloat, height: CGFloat) {
    defer {
      lastSelfSizingMeasurement = (width: width, height: height)
    }

    guard
      let previous = lastSelfSizingMeasurement,
      abs(previous.width - width) < 0.5,
      abs(previous.height - height) >= 0.5,
      !didReportUnstableSelfSizing,
      let message
    else {
      return
    }

    didReportUnstableSelfSizing = true
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
        "previous_height": Double(previous.height),
        "fitted_height": Double(height),
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
    let bubble = messageView.bubbleView
    let originalColor = bubble.backgroundColor ?? .systemGray6
    let isEmojiOrSticker = messageView.isEmojiOnlyMessage || messageView.isSticker
    // let highlightColor = isEmojiOrSticker ? ThemeManager.shared.selected.accent.withAlphaComponent(0.3) :
    // originalColor
    let highlightColor = messageView.outgoing ? ThemeManager.shared.selected.bubbleBackground
      .lighten(by: 0.3)
      : ThemeManager.shared.selected.accent.withAlphaComponent(0.4)
    messageView.highlightMediaOverlay()
    UIView.animate(withDuration: 0.18, animations: {
      bubble.backgroundColor = highlightColor
    }) { _ in
      UIView.animate(withDuration: 0.5, delay: 0.2, options: [], animations: {
        bubble.backgroundColor = originalColor
      }, completion: nil)
    }
  }

  func clearHighlight() {
    guard let messageView else { return }
    guard !isServiceMessage else { return }
    let bubble = messageView.bubbleView
    bubble.layer.removeAllAnimations()
    bubble.backgroundColor = messageView.bubbleColor
    messageView.clearMediaHighlight()
  }
}

extension MessageCollectionViewCell {
  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer == panGesture else { return true }

    // Do not begin swipe-to-reply if replying is not allowed
    if !canReply { return false }

    let velocity = panGesture.velocity(in: contentView)

    // If the gesture starts as a rightward swipe, let the navigation controller
    // (back swipe) handle it by declining recognition here.
    let isLikelyBackSwipe = velocity.x > 0 && abs(velocity.x) > abs(velocity.y)
    if isLikelyBackSwipe { return false }

    // Calculate angle and only allow nearly horizontal swipes
    // An 16 degree angle corresponds to tan(16°) ≈ 0.287
    // This means vertical component should be at most 0.287 times the horizontal component
    // let maxAngleTangent: CGFloat = 0.287 // tan(16°)
    let maxAngleTangent: CGFloat = 0.4452286853 // tan(24°)
    let isHorizontalEnough = abs(velocity.y) <= abs(velocity.x) * maxAngleTangent

    return abs(velocity.x) > abs(velocity.y) && isHorizontalEnough // Must be predominantly horizontal
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // Allow the system's interactive pop (back swipe) recognizer to proceed when present.
    if otherGestureRecognizer is UIScreenEdgePanGestureRecognizer {
      return true
    }
    return false
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
        initialTranslation = translation.x
        replyIndicator.isHidden = false
        replyIndicator.alpha = 1
        replyIndicator.reset()
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
    let isTrailingSwipe = adjustedTranslation < 0

    guard isTrailingSwipe else {
      resetSwipeState()
      return
    }

    let maxTranslation: CGFloat = 80
    let progress = min(abs(adjustedTranslation) / maxTranslation, 1)
    let boundedTranslation = -maxTranslation * progress

    messageView?.transform = CGAffineTransform(translationX: boundedTranslation, y: 0)
    nameLabel.transform = CGAffineTransform(translationX: boundedTranslation, y: 0)
    avatarView?.transform = CGAffineTransform(translationX: boundedTranslation, y: 0)

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
    let isTrailingSwipe = adjustedTranslation < 0

    // Only trigger for trailing swipes (left direction)
    guard isTrailingSwipe else {
      UIView.animate(withDuration: 0.4) {
        self.messageView?.transform = .identity
        self.nameLabel.transform = .identity
        self.avatarView?.transform = .identity
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
      self.replyIndicator.alpha = 0
    } completion: { _ in
      if shouldTrigger {
        self.delegate?.didSwipeToReply(for: self.message)
      }
      self.resetSwipeState()
    }
  }

  private func resetSwipeState() {
    replyIndicator.isHidden = true
    replyIndicator.alpha = 1
    replyIndicator.reset()
    initialTranslation = 0
    swipeActive = false

    messageView?.transform = .identity
    nameLabel.transform = .identity
    avatarView?.transform = .identity
  }

  func setupReplyIndicator() {
    contentView.addSubview(replyIndicator)

    replyViewCenterYConstraint = replyIndicator.centerYAnchor
      .constraint(equalTo: contentView.centerYAnchor, constant: topBubblePadding / 2)

    NSLayoutConstraint.activate(
      [
        replyViewCenterYConstraint,
        replyIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: 0),
        replyIndicator.widthAnchor.constraint(equalToConstant: 40),
        replyIndicator.heightAnchor.constraint(equalToConstant: 40),
      ]
    )
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

  func setupBaseMessageConstraints() {
    let newMessageView = UIMessageView(
      fullMessage: message,
      spaceId: spaceId,
      displayMode: displayMode,
      bubbleTailSide: bubbleTailSide
    )
    newMessageView.translatesAutoresizingMaskIntoConstraints = false
    newMessageView.onPhotoTap = { [weak self] message, sourceView, sourceImage, url in
      self?.onPhotoTap?(message, sourceView, sourceImage, url)
    }
    contentView.addSubview(newMessageView)

    let topConstraint: NSLayoutConstraint
    let leadingConstraint: NSLayoutConstraint
    let trailingConstraint: NSLayoutConstraint

    // Bubble top constraint
    topConstraint = newMessageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: topBubblePadding)

    // Sync reply view
    replyViewCenterYConstraint.constant = topBubblePadding / 2

    if usesThreadLayout, !outgoing, let avatarOrSpacer = avatarSpacerView {
      leadingConstraint = newMessageView.leadingAnchor.constraint(equalTo: avatarOrSpacer.trailingAnchor, constant: 3)
      trailingConstraint = newMessageView.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor,
        constant: firstInGroup ? -(10 + horizontalPadding) : -horizontalPadding
      )
    } else {
      leadingConstraint = newMessageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding)
      trailingConstraint = newMessageView.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor,
        constant: -horizontalPadding
      )
    }
    NSLayoutConstraint.activate([
      leadingConstraint,
      trailingConstraint,
      topConstraint,
      newMessageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])

    messageView = newMessageView
  }

  // Add avatar if we have user info
  func resetCell() {
    messageView?.stopShineAnimation()

    messageView?.removeFromSuperview()
    messageView = nil

    nameLabel.removeFromSuperview()
    avatarView?.removeFromSuperview()
    avatarView = nil
    avatarSpacerView?.removeFromSuperview()
    avatarSpacerView = nil
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
