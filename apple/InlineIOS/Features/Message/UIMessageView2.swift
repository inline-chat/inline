import InlineIOSUI
import InlineKit
import InlineProtocol
import InlineTheme
import InlineUI
import TextProcessing
import UIKit

/// Experimental typed compatibility surface for the next message renderer.
///
/// Keeping V2 as a `UIMessageView` subtype preserves the concrete geometry and interaction
/// contract used by the collection, context-menu, media, and send-animation paths. V2 can replace
/// its internal hierarchy and update behavior without making those callers route through an
/// untyped wrapper or a hidden legacy child.
final class UIMessageView2: UIMessageView {
  private enum NodeID {
    static let serviceContainer = MessageLayoutNodeIDV2("service-container")
    static let forwardHeader = MessageLayoutNodeIDV2("forward-header")
    static let reply = MessageLayoutNodeIDV2("reply")
    static let legacyFile = MessageLayoutNodeIDV2("legacy-file")
    static let photo = MessageLayoutNodeIDV2("photo")
    static let video = MessageLayoutNodeIDV2("video")
    static let document = MessageLayoutNodeIDV2("document")
    static let voice = MessageLayoutNodeIDV2("voice")
    static let text = MessageLayoutNodeIDV2("text")
    static let metadata = MessageLayoutNodeIDV2("metadata")
    static let floatingMetadata = MessageLayoutNodeIDV2("floating-metadata")
    static let reactions = MessageLayoutNodeIDV2("reactions")
    static let replyThreadSummary = MessageLayoutNodeIDV2("reply-thread-summary")
    static let actions = MessageLayoutNodeIDV2("actions")

    static func externalTask(_ index: Int, _ attachmentID: Int64) -> MessageLayoutNodeIDV2 {
      MessageLayoutNodeIDV2("external-task-\(attachmentID)-\(index)")
    }

    static func urlPreview(_ index: Int, _ attachmentID: Int64) -> MessageLayoutNodeIDV2 {
      MessageLayoutNodeIDV2("url-preview-\(attachmentID)-\(index)")
    }
  }

  private final class LayoutPlanBox: NSObject {
    let plan: MessageBubbleLayoutV2

    init(_ plan: MessageBubbleLayoutV2) {
      self.plan = plan
    }
  }

  private struct LeafMeasurementKey: Hashable {
    let nodeID: MessageLayoutNodeIDV2
    let widthPixels: Int
    let generation: Int
    let fillsWidth: Bool
    let contentSizeCategory: UIContentSizeCategory
    let layoutDirection: Int
  }

  private struct DisappearingSnapshot {
    let generation: UInt
    let view: UIView
  }

  private static let layoutCache: NSCache<NSString, LayoutPlanBox> = {
    let cache = NSCache<NSString, LayoutPlanBox>()
    cache.countLimit = 512
    cache.totalCostLimit = 8 * 1_024 * 1_024
    return cache
  }()

  private static let attributedTextCache: NSCache<NSString, NSAttributedString> = {
    let cache = NSCache<NSString, NSAttributedString>()
    cache.countLimit = 1_000
    return cache
  }()

  private static func animationEvent(_ value: @autoclosure () -> String) {
    #if DEBUG || DEBUG_BUILD
    NSLog("%@", "MV2_ANIM \(value())")
    #endif
  }

  private let maximumBubbleWidth: CGFloat
  private var layoutContentSignature = 0
  private var currentLayout: MessageBubbleLayoutV2?
  private var currentLayoutKey: NSString?
  private var bubbleNodeViews: [MessageLayoutNodeIDV2: UIView] = [:]
  private var rootNodeViews: [MessageLayoutNodeIDV2: UIView] = [:]
  private var attachmentViews: [MessageLayoutNodeIDV2: UIView] = [:]
  private var leafMeasurements: [LeafMeasurementKey: CGSize] = [:]
  private var leafMeasurementGenerations: [MessageLayoutNodeIDV2: Int] = [:]
  private var actionButtonRows: [[MessageActionButton]] = []
  private let richContentView = RichBlockContentViewV2()
  private var currentRichPlan: RichBlockLayoutPlanV2?
  private var transitionOldRichPlan: RichBlockLayoutPlanV2?
  private var transitionAppearingViews: [UIView] = []
  private var transitionDisappearingSnapshots: [DisappearingSnapshot] = []
  private(set) var geometryTransitionGeneration: UInt = 0
  private var activeGeometryTransitionGeneration: UInt?
  private var renderedRichContentSignature: Int?
  private var renderedRichContentByteCount: Int?
  private var renderedRichTextHash: Int?
  private weak var richLinkLongPress: UILongPressGestureRecognizer?
  private var didInstallReplyTap = false
  private var didInstallRichInteractions = false
  private var layoutTraitRegistration: UITraitChangeRegistration?

  var onGeometryChange: ((MessageBubbleLayoutV2, MessageBubbleLayoutV2) -> Void)?

  init(
    fullMessage: FullMessage,
    spaceId: Int64?,
    displayMode: MessageDisplayMode,
    bubbleTailSide: MessageBubbleTailSide,
    maximumBubbleContentWidth: CGFloat,
    theme: IOSThemeSnapshot,
    animatedReactionEmoji: String? = nil,
    initialMetadataStatus: MessageSendingStatus? = nil
  ) {
    maximumBubbleWidth = maximumBubbleContentWidth
    super.init(
      fullMessage: fullMessage,
      spaceId: spaceId,
      displayMode: displayMode,
      bubbleTailSide: bubbleTailSide,
      maximumBubbleContentWidth: maximumBubbleContentWidth,
      theme: theme,
      animatedReactionEmoji: animatedReactionEmoji,
      initialMetadataStatus: initialMetadataStatus,
      buildHierarchy: false
    )

    layoutContentSignature = fullMessage.hashValue
    buildManualHierarchy()
    layoutTraitRegistration = registerForTraitChanges([
      UITraitPreferredContentSizeCategory.self,
      UITraitDisplayScale.self,
      UITraitLayoutDirection.self,
    ]) { (view: UIMessageView2, _: UITraitCollection) in
      view.refreshLayoutTraits()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    let width = bounds.width > 0 ? bounds.width : maximumBubbleWidth
    return CGSize(
      width: UIView.noIntrinsicMetric,
      height: measuredLayout(containerWidth: width)?.size.height ?? 0
    )
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let width = size.width.isFinite && size.width > 0 ? size.width : maximumBubbleWidth
    return measuredLayout(containerWidth: width)?.size ?? CGSize(width: width, height: 0)
  }

  override func systemLayoutSizeFitting(
    _ targetSize: CGSize,
    withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
    verticalFittingPriority: UILayoutPriority
  ) -> CGSize {
    sizeThatFits(targetSize)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // The collection owns the single geometry transaction. Re-applying the measured final plan
    // from an incidental Auto Layout pass would otherwise jump the bubble and its children to the
    // destination before that transaction can interpolate them.
    guard activeGeometryTransitionGeneration == nil else { return }
    guard bounds.width > 0, let layout = measuredLayout(containerWidth: bounds.width) else { return }
    currentLayout = layout
    apply(layout: layout, richPlan: currentRichPlan)
  }

  private func refreshLayoutTraits() {
    if message.isServiceMessage {
      serviceLabel.attributedText = serviceAttributedText()
    } else {
      messageLabel.attributedText = attributedMessageText()
    }
    renderedRichContentSignature = nil
    renderedRichContentByteCount = nil
    renderedRichTextHash = nil
    leafMeasurements.removeAll(keepingCapacity: true)
    invalidateMeasuredContent()
  }

  override func applyTheme(_ theme: IOSThemeSnapshot) {
    guard self.theme != theme else { return }
    super.applyTheme(theme)
    renderedRichContentSignature = nil
    renderedRichContentByteCount = nil
    renderedRichTextHash = nil
    leafMeasurements.removeAll(keepingCapacity: true)
    invalidateMeasuredContent()
  }

  override func setupAppearance() {
    super.setupAppearance()
    updateReactionBackgroundOverridesForCurrentMessage()
  }

  override func attributedMessageText() -> NSAttributedString? {
    guard let text = fullMessage.displayText else { return nil }
    let entities = fullMessage.translationEntities ?? message.entities
    let key = [
      String(message.stableId),
      text,
      String(describing: entities),
      theme.preset.rawValue,
      theme.variant.rawValue,
      traitCollection.preferredContentSizeCategory.rawValue,
      outgoing ? "outgoing" : "incoming",
    ].joined(separator: "|") as NSString
    if let cached = Self.attributedTextCache.object(forKey: key) {
      return cached
    }

    let baseSize: CGFloat = isSingleEmojiMessage ? 80 : isTripleEmojiMessage ? 70 : isEmojiOnlyMessage ? 32 : 17
    let baseFont = UIFont.systemFont(ofSize: baseSize)
    let font = UIFontMetrics(forTextStyle: .body).scaledFont(
      for: baseFont,
      compatibleWith: traitCollection
    )
    let codeBlockBackgroundColor = outgoing ? nil : textColor.withAlphaComponent(0.05)
    let inlineCodeBackgroundColor = outgoing ? nil : textColor.withAlphaComponent(0.06)
    let attributed = ProcessEntities.toAttributedString(
      text: text,
      entities: entities,
      configuration: .init(
        font: font,
        palette: .init(
          primaryColor: textColor,
          linkColor: outgoing ? .white : theme.primary.uiColor,
          secondaryColor: outgoing
            ? UIColor.white.withAlphaComponent(0.7)
            : theme.incomingSecondaryText.uiColor
        ),
        codeBlockBackgroundColor: codeBlockBackgroundColor,
        inlineCodeBackgroundColor: inlineCodeBackgroundColor
      )
    )
    detectAndStyleLinks(in: text, attributedString: attributed)
    Self.attributedTextCache.setObject(attributed, forKey: key, cost: max(64, attributed.length * 8))
    return attributed
  }

  func prepareGeometryTransition(from oldLayout: MessageBubbleLayoutV2, generation: UInt) {
    guard generation == geometryTransitionGeneration else {
      Self
        .animationEvent(
          "prepare-stale message=\(message.stableId) requested=\(generation) current=\(geometryTransitionGeneration)"
        )
      return
    }
    activeGeometryTransitionGeneration = generation
    Self.animationEvent(
      "prepare message=\(message.stableId) generation=\(generation) old=\(oldLayout.size.height)"
    )
    let presentation = capturePresentationGeometry()
    apply(layout: oldLayout, richPlan: transitionOldRichPlan ?? currentRichPlan)
    restorePresentationGeometry(presentation)
    richContentView.restorePresentationGeometry()
  }

  func applyGeometryTransition(to newLayout: MessageBubbleLayoutV2, generation: UInt) {
    guard generation == geometryTransitionGeneration else {
      Self
        .animationEvent(
          "apply-stale message=\(message.stableId) requested=\(generation) current=\(geometryTransitionGeneration)"
        )
      return
    }
    currentLayout = newLayout
    apply(layout: newLayout, richPlan: currentRichPlan)
    reactionsFlowView.applySynchronizedGeometryTransition(generation: geometryTransitionGeneration)
    for view in transitionAppearingViews {
      view.alpha = 1
      view.transform = .identity
    }
    transitionAppearingViews.removeAll(keepingCapacity: true)
    for snapshot in transitionDisappearingSnapshots {
      snapshot.view.alpha = 0
      snapshot.view.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
    }
    transitionOldRichPlan = nil
    Self.animationEvent(
      "apply message=\(message.stableId) generation=\(generation) new=\(newLayout.size.height)"
    )
  }

  var hasPendingContentTransition: Bool {
    transitionOldRichPlan != currentRichPlan
      || !transitionAppearingViews.isEmpty
      || !transitionDisappearingSnapshots.isEmpty
      || richContentView.hasPendingTransitionSnapshots
      || reactionsFlowView.hasPendingSynchronizedGeometryTransition
  }

  func finishGeometryTransition(generation: UInt) {
    guard generation == geometryTransitionGeneration else {
      Self
        .animationEvent(
          "finish-stale message=\(message.stableId) requested=\(generation) current=\(geometryTransitionGeneration)"
        )
      return
    }
    for snapshot in transitionDisappearingSnapshots where snapshot.generation == generation {
      snapshot.view.removeFromSuperview()
    }
    transitionDisappearingSnapshots.removeAll { $0.generation == generation }
    richContentView.finishTransition(generation: generation)
    reactionsFlowView.finishSynchronizedGeometryTransition(generation: generation)
    activeGeometryTransitionGeneration = nil
    if let currentLayout {
      UIView.performWithoutAnimation {
        apply(layout: currentLayout, richPlan: currentRichPlan)
      }
    }
    Self.animationEvent("finish message=\(message.stableId) generation=\(generation)")
  }

  func cancelPendingGeometryTransitions() {
    Self.animationEvent("cancel message=\(message.stableId) generation=\(geometryTransitionGeneration)")
    layer.removeAllAnimations()
    bubbleView.layer.removeAllAnimations()
    for view in bubbleNodeViews.values {
      view.layer.removeAllAnimations()
      view.alpha = 1
      view.transform = .identity
    }
    for view in rootNodeViews.values {
      view.layer.removeAllAnimations()
      view.alpha = 1
      view.transform = .identity
    }
    for view in transitionAppearingViews {
      view.alpha = 1
      view.transform = .identity
    }
    transitionAppearingViews.removeAll(keepingCapacity: true)
    for snapshot in transitionDisappearingSnapshots {
      snapshot.view.removeFromSuperview()
    }
    transitionDisappearingSnapshots.removeAll(keepingCapacity: true)
    richContentView.cancelTransitions()
    reactionsFlowView.cancelSynchronizedGeometryTransition()
    transitionOldRichPlan = nil
    activeGeometryTransitionGeneration = nil
    if let currentLayout {
      UIView.performWithoutAnimation {
        apply(layout: currentLayout, richPlan: currentRichPlan)
      }
    }
  }

  private func apply(layout: MessageBubbleLayoutV2, richPlan: RichBlockLayoutPlanV2?) {
    if message.isServiceMessage {
      if let frame = layout.nodeFrames[NodeID.serviceContainer] {
        serviceContainerView.frame = frame
        serviceLabel.frame = serviceContainerView.bounds.insetBy(dx: 10, dy: 6)
      }
      return
    }

    bubbleView.frame = layout.bubbleFrame
    bubbleView.layoutIfNeeded()

    for (id, view) in bubbleNodeViews {
      guard let frame = layout.nodeFrames[id] else {
        view.isHidden = true
        continue
      }
      view.isHidden = false
      view.frame = convertToBubbleContent(frame)
      if view === reactionsFlowView {
        reactionsFlowView.setV2LayoutWidth(frame.width)
      }
      if view === richContentView, let richPlan {
        richContentView.isHidden = false
        richContentView.applyLayout(richPlan)
        messageLabel.frame = view.frame
        messageLabel.alpha = 0
        messageLabel.isUserInteractionEnabled = false
      } else if view === richContentView {
        richContentView.isHidden = true
        messageLabel.frame = view.frame
        messageLabel.alpha = 1
        messageLabel.isUserInteractionEnabled = true
      }
    }

    for (id, view) in rootNodeViews {
      guard let frame = layout.nodeFrames[id] else {
        view.isHidden = true
        continue
      }
      view.isHidden = false
      view.frame = frame
      if view === reactionsFlowView {
        reactionsFlowView.setV2LayoutWidth(frame.width)
      }
      if view === messageActionsContainer {
        layoutMessageActionButtons(in: view.bounds)
      }
    }
  }

  private struct PresentationGeometry {
    let view: UIView
    let bounds: CGRect
    let position: CGPoint
    let transform: CGAffineTransform
    let alpha: CGFloat
  }

  private func capturePresentationGeometry() -> [PresentationGeometry] {
    let views = [bubbleView, serviceContainerView, serviceLabel, messageLabel, richContentView]
      + Array(bubbleNodeViews.values)
      + Array(rootNodeViews.values)
      + transitionDisappearingSnapshots.map(\.view)
    var seen: Set<ObjectIdentifier> = []
    return views.compactMap { view in
      guard seen.insert(ObjectIdentifier(view)).inserted,
            let presentation = view.layer.presentation()
      else { return nil }
      return .init(
        view: view,
        bounds: presentation.bounds,
        position: presentation.position,
        transform: CATransform3DGetAffineTransform(presentation.transform),
        alpha: CGFloat(presentation.opacity)
      )
    }
  }

  private func restorePresentationGeometry(_ states: [PresentationGeometry]) {
    for state in states {
      state.view.bounds = state.bounds
      state.view.center = state.position
      state.view.transform = state.transform
      state.view.alpha = state.alpha
    }
  }

  override func updateBubbleTail(side: MessageBubbleTailSide, animated: Bool) {
    guard bubbleTailSide != side else { return }
    let width = bounds.width > 0 ? bounds.width : maximumBubbleWidth
    let oldLayout = measuredLayout(containerWidth: width)
    bubbleTailSide = side
    bubbleView.configure(side: side, animated: false)
    invalidateMeasuredContent()
    guard let newLayout = measuredLayout(containerWidth: width) else { return }
    if animated, let oldLayout, oldLayout != newLayout {
      onGeometryChange?(oldLayout, newLayout)
    } else {
      currentLayout = newLayout
      apply(layout: newLayout, richPlan: currentRichPlan)
    }
  }

  override func canUpdateReactionsInPlace(to updatedMessage: FullMessage) -> Bool {
    canApplySnapshot(updatedMessage)
  }

  override func updateReactions(to updatedMessage: FullMessage, animatedEmoji: String?) {
    applySnapshot(updatedMessage, animatedReactionEmoji: animatedEmoji)
  }

  override func updateDeliveryAcknowledgement(to updatedMessage: FullMessage) {
    let width = bounds.width > 0 ? bounds.width : maximumBubbleWidth
    let oldLayout = measuredLayout(containerWidth: width)
    replaceFullMessageSnapshot(updatedMessage)
    layoutContentSignature = updatedMessage.hashValue
    metadataView.updateMessage(updatedMessage, animated: true)
    floatingMetadataView.updateMessage(updatedMessage, animated: true)
    invalidateLeafMeasurement(NodeID.floatingMetadata)
    setupAppearance()
    invalidateMeasuredContent()
    guard let newLayout = measuredLayout(containerWidth: width) else { return }
    if let oldLayout, oldLayout != newLayout {
      onGeometryChange?(oldLayout, newLayout)
    } else {
      apply(layout: newLayout, richPlan: currentRichPlan)
    }
  }

  override func linkURL(atPointInMessageView pointInMessageView: CGPoint) -> URL? {
    if currentRichPlan != nil {
      let point = convert(pointInMessageView, to: richContentView)
      if let hit = richContentView.entityHit(at: point) {
        return linkURL(at: hit.characterIndex, in: hit.text)
      }
    }
    return super.linkURL(atPointInMessageView: pointInMessageView)
  }

  override func sendAnimationTextView() -> UITextView {
    currentRichPlan == nil ? messageLabel : (richContentView.primaryTextSurface ?? messageLabel)
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    if gestureRecognizer === richLinkLongPress {
      let point = gestureRecognizer.location(in: richContentView)
      guard let hit = richContentView.entityHit(at: point) else { return false }
      return linkURL(at: hit.characterIndex, in: hit.text) != nil
    }
    return super.gestureRecognizerShouldBegin(gestureRecognizer)
  }

  func canApplySnapshot(_ updatedMessage: FullMessage) -> Bool {
    guard fullMessage.id == updatedMessage.id,
          message.isServiceMessage == updatedMessage.message.isServiceMessage,
          outgoing == (updatedMessage.message.out == true)
    else { return false }
    return true
  }

  func containsHorizontalScroller(at pointInMessageView: CGPoint) -> Bool {
    var candidate = hitTest(pointInMessageView, with: nil)
    while let view = candidate, view !== self {
      if let scrollView = view as? UIScrollView,
         scrollView.contentSize.width > scrollView.bounds.width + 1
      {
        return true
      }
      candidate = view.superview
    }
    return false
  }

  func applySnapshot(_ updatedMessage: FullMessage, animatedReactionEmoji: String? = nil) {
    guard canApplySnapshot(updatedMessage) else { return }
    finishGeometryTransition(generation: geometryTransitionGeneration)
    let width = bounds.width > 0 ? bounds.width : maximumBubbleWidth
    let oldLayout = measuredLayout(containerWidth: width)
    transitionOldRichPlan = currentRichPlan
    geometryTransitionGeneration &+= 1
    Self.animationEvent(
      "snapshot message=\(message.stableId) generation=\(geometryTransitionGeneration) reactions=\(fullMessage.reactions.count)->\(updatedMessage.reactions.count) emoji=\(animatedReactionEmoji ?? "nil")"
    )
    let previousMessage = fullMessage
    let reactionsMoveBetweenContainers = reactionsAreExternal(in: previousMessage)
      != reactionsAreExternal(in: updatedMessage)
    if !reactionsMoveBetweenContainers {
      if !previousMessage.reactions.isEmpty, updatedMessage.reactions.isEmpty {
        retainTransitionSnapshot(of: reactionsFlowView)
      } else if previousMessage.reactions.isEmpty, !updatedMessage.reactions.isEmpty {
        markAppearing(reactionsFlowView, scale: 0.96)
      }
    }

    replaceFullMessageSnapshot(updatedMessage)
    layoutContentSignature = updatedMessage.hashValue
    reconcileRetainedNodePlacement(from: previousMessage)
    if message.isServiceMessage {
      serviceLabel.attributedText = serviceAttributedText()
    } else {
      messageLabel.attributedText = attributedMessageText()
      metadataView.updateMessage(updatedMessage, animated: false)
      floatingMetadataView.updateMessage(updatedMessage, animated: false)
      invalidateLeafMeasurement(NodeID.floatingMetadata)
      updateRetainedContentViews(from: previousMessage, to: updatedMessage)
      if previousMessage.reactions != updatedMessage.reactions || animatedReactionEmoji != nil {
        reactionsFlowView.configure(
          with: updatedMessage.groupedReactions,
          animatedEmoji: animatedReactionEmoji,
          synchronizedWithGeometry: true,
          synchronizedContentCrossfade: !reactionsMoveBetweenContainers
            && !previousMessage.reactions.isEmpty
            && !updatedMessage.reactions.isEmpty,
          transitionGeneration: geometryTransitionGeneration
        )
      }
      if forwardProjectionChanged(from: previousMessage, to: updatedMessage)
        || replyProjectionChanged(from: previousMessage, to: updatedMessage)
      {
        updateForwardAndReplyContent()
      }
      if replyThreadProjectionChanged(from: previousMessage, to: updatedMessage) {
        updateReplyThreadSummaryContent()
        invalidateLeafMeasurement(NodeID.replyThreadSummary)
      }
      if previousMessage.message.actions != updatedMessage.message.actions {
        updateMessageActionsContent(with: updatedMessage)
      }
      setupAppearance()
    }

    currentLayout = nil
    currentLayoutKey = nil
    currentRichPlan = nil
    invalidateIntrinsicContentSize()
    setNeedsLayout()
    guard let newLayout = measuredLayout(containerWidth: width) else {
      cancelPendingGeometryTransitions()
      return
    }
    guard let oldLayout, let onGeometryChange else {
      applyGeometryTransition(to: newLayout, generation: geometryTransitionGeneration)
      finishGeometryTransition(generation: geometryTransitionGeneration)
      return
    }
    onGeometryChange(oldLayout, newLayout)
  }

  private func buildManualHierarchy() {
    if message.isServiceMessage {
      buildServiceHierarchy()
      return
    }

    bubbleView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(bubbleView)

    if shouldShowForwardHeader {
      forwardHeaderLabel.textColor = forwardHeaderTextColor
      forwardHeaderLabel.text = forwardHeaderText
      registerBubbleNode(forwardHeaderLabel, id: NodeID.forwardHeader)
    }

    if message.repliedToMessageId != nil {
      if let embeddedMessage = fullMessage.repliedToMessage {
        embedView.configure(
          embeddedMessage: embeddedMessage,
          kind: .replyInMessage,
          outgoing: outgoing,
          isOnlyEmoji: isEmojiOnlyMessage,
          thumbnailReloadMessage: fullMessage.message
        )
      } else {
        embedView.showNotLoaded(
          kind: .replyInMessage,
          outgoing: outgoing,
          isOnlyEmoji: isEmojiOnlyMessage
        )
        ensureRepliedMessageCachedOnce()
      }
      installReplyTapIfNeeded()
      registerBubbleNode(embedView, id: NodeID.reply)
    }

    if fullMessage.file != nil {
      registerBubbleNode(photoView, id: NodeID.legacyFile)
    }
    if fullMessage.photoInfo != nil {
      registerBubbleNode(newPhotoView, id: NodeID.photo)
    }
    if fullMessage.videoInfo != nil {
      registerBubbleNode(videoView, id: NodeID.video)
    }
    if shouldShowVoiceMessage {
      registerBubbleNode(voiceMessageViewController.view, id: NodeID.voice)
    } else if fullMessage.documentInfo != nil {
      registerBubbleNode(documentView, id: NodeID.document)
    }

    if shouldRenderRichContentV2 {
      installRichInteractionsIfNeeded()
      registerBubbleNode(richContentView, id: NodeID.text)
      messageLabel.translatesAutoresizingMaskIntoConstraints = true
      messageLabel.alpha = 0
      messageLabel.isUserInteractionEnabled = false
      bubbleView.contentView.addSubview(messageLabel)
    } else {
      messageLabel.isUserInteractionEnabled = true
      if message.hasText {
        registerBubbleNode(messageLabel, id: NodeID.text)
      }
    }

    for (index, attachment) in fullMessage.attachments.enumerated() {
      if let externalTask = attachment.externalTask, let userInfo = attachment.userInfo {
        let id = NodeID.externalTask(index, attachment.id)
        let view = MessageAttachmentEmbed()
        view.configure(
          userInfo: userInfo,
          outgoing: outgoing,
          url: URL(string: externalTask.url ?? ""),
          issueIdentifier: nil,
          title: externalTask.title,
          externalTask: externalTask,
          messageId: message.messageId,
          chatId: message.chatId
        )
        attachmentViews[id] = view
        registerBubbleNode(view, id: id)
      }
      if attachment.urlPreview != nil {
        let id = NodeID.urlPreview(index, attachment.id)
        let view = createURLPreviewView(for: attachment)
        attachmentViews[id] = view
        registerBubbleNode(view, id: id)
      }
    }

    if floatingMetadataTargetV2 != nil {
      registerBubbleNode(floatingMetadataView, id: NodeID.floatingMetadata)
    } else {
      registerBubbleNode(metadataView, id: NodeID.metadata)
    }

    if reactionsAreExternal(in: fullMessage) {
      registerRootNode(reactionsFlowView, id: NodeID.reactions)
    } else {
      registerBubbleNode(reactionsFlowView, id: NodeID.reactions)
    }
    reactionsFlowView.configure(with: fullMessage.groupedReactions)

    if shouldShowReplyThreadSummary, message.replyThreadSummary != nil {
      registerBubbleNode(replyThreadSummaryView, id: NodeID.replyThreadSummary)
      configureReplyThreadSummaryV2()
    }

    if hasMessageActionRowsV2 {
      setupMessageActionsV2()
      messageActionsContainer.translatesAutoresizingMaskIntoConstraints = true
      registerRootNode(messageActionsContainer, id: NodeID.actions)
    }

    setupAppearance()
    addGestureRecognizer()
    setupDoubleTapGestureRecognizer()
    setupTranslationObserver()
  }

  private func buildServiceHierarchy() {
    serviceContainerView.translatesAutoresizingMaskIntoConstraints = true
    serviceLabel.translatesAutoresizingMaskIntoConstraints = true
    serviceLabel.attributedText = serviceAttributedText()
    serviceLabel.isUserInteractionEnabled = true
    serviceLabel.addGestureRecognizer(UITapGestureRecognizer(
      target: self,
      action: #selector(handleServiceMessageTap(_:))
    ))
    serviceContainerView.addSubview(serviceLabel)
    addSubview(serviceContainerView)
  }

  private func registerBubbleNode(_ view: UIView, id: MessageLayoutNodeIDV2) {
    view.translatesAutoresizingMaskIntoConstraints = true
    if view.superview !== bubbleView.contentView {
      view.removeFromSuperview()
      bubbleView.contentView.addSubview(view)
    }
    bubbleNodeViews[id] = view
  }

  private func registerRootNode(_ view: UIView, id: MessageLayoutNodeIDV2) {
    view.translatesAutoresizingMaskIntoConstraints = true
    if view.superview !== self {
      view.removeFromSuperview()
      addSubview(view)
    }
    rootNodeViews[id] = view
  }

  private func measuredLayout(containerWidth: CGFloat) -> MessageBubbleLayoutV2? {
    guard ensureRichPlan(containerWidth: containerWidth) else { return nil }
    let key = layoutCacheKey(containerWidth: containerWidth)
    if currentLayoutKey == key, let currentLayout {
      return currentLayout
    }
    if let cached = Self.layoutCache.object(forKey: key) {
      currentLayoutKey = key
      currentLayout = cached.plan
      return cached.plan
    }
    guard let plan = makeMeasuredLayout(containerWidth: containerWidth) else { return nil }
    currentLayoutKey = key
    currentLayout = plan
    Self.layoutCache.setObject(
      LayoutPlanBox(plan),
      forKey: key,
      cost: max(256, plan.nodeFrames.count * 96)
    )
    return plan
  }

  private func makeMeasuredLayout(containerWidth: CGFloat) -> MessageBubbleLayoutV2? {
    if message.isServiceMessage {
      let availableWidth = max(1, containerWidth * 0.9 - 20)
      let labelSize = serviceLabel.sizeThatFits(
        CGSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
      )
      let containerSize = CGSize(
        width: containerWidth * 0.9,
        height: ceil(labelSize.height) + 12
      )
      let x = floor((containerWidth - containerSize.width) / 2)
      return MessageBubbleLayoutV2(
        size: CGSize(width: containerWidth, height: containerSize.height + 8),
        bubbleFrame: .zero,
        bubbleContentFrame: .zero,
        nodeFrames: [
          NodeID.serviceContainer: CGRect(
            x: x,
            y: 4,
            width: containerSize.width,
            height: containerSize.height
          ),
        ],
        footerPlacement: nil
      )
    }

    let tailSide = resolvedTailSide
    let tailWidth = MessageBubbleView.tailWidth(for: tailSide)
    // `maximumBubbleWidth` is the legacy tail-excluding content limit supplied by the cell.
    let maximumWidth = min(containerWidth, maximumBubbleWidth + tailWidth)
    let maximumContentWidth = max(1, maximumWidth - tailWidth)
    let standardInsets = MessageLayoutInsetsV2(top: 0, leading: 12, bottom: 0, trailing: 12)
    let emojiInsets = MessageLayoutInsetsV2.zero
    let hasFullBleedMedia = bubbleNodeViews[NodeID.legacyFile] != nil
      || bubbleNodeViews[NodeID.photo] != nil
      || bubbleNodeViews[NodeID.video] != nil
    let mediaOnlyChrome = hasFullBleedMedia && !message.hasText
    var flowNodes: [MessageMeasuredNodeV2] = []
    var belowBubbleNodes: [MessageMeasuredNodeV2] = []
    var overlayNodes: [MessageOverlayNodeV2] = []

    func append(
      _ id: MessageLayoutNodeIDV2,
      size: CGSize,
      widthBehavior: MessageMeasuredNodeV2.WidthBehavior = .natural,
      forcesMaximumWidth: Bool = false,
      alignment: MessageMeasuredNodeV2.HorizontalAlignment = .leading,
      insets: MessageLayoutInsetsV2 = .zero,
      spacing: CGFloat? = nil
    ) {
      flowNodes.append(.init(
        id: id,
        size: size,
        spacingBefore: spacing ?? (flowNodes.isEmpty ? 0 : 6),
        widthBehavior: widthBehavior,
        forcesMaximumWidth: forcesMaximumWidth,
        horizontalAlignment: alignment,
        insets: insets
      ))
    }

    if bubbleNodeViews[NodeID.forwardHeader] != nil {
      let insets = mediaOnlyChrome
        ? MessageLayoutInsetsV2(top: 6, leading: 12, bottom: 0, trailing: 12)
        : standardInsets
      append(
        NodeID.forwardHeader,
        size: measuredSize(
          of: forwardHeaderLabel,
          nodeID: NodeID.forwardHeader,
          maximumWidth: maximumContentWidth - insets.leading - insets.trailing
        ),
        widthBehavior: .fill,
        insets: insets,
        spacing: 0
      )
    }
    if bubbleNodeViews[NodeID.reply] != nil {
      let insets = mediaOnlyChrome
        ? MessageLayoutInsetsV2(top: 6, leading: 6, bottom: 0, trailing: 6)
        : standardInsets
      append(
        NodeID.reply,
        size: CGSize(
          width: min(200, max(1, maximumContentWidth - insets.leading - insets.trailing)),
          height: EmbedMessageView.height
        ),
        widthBehavior: .fill,
        insets: insets,
        spacing: flowNodes.isEmpty ? 0 : 1
      )
    }
    var primaryMediaWidth: CGFloat?
    if bubbleNodeViews[NodeID.legacyFile] != nil {
      let size = measuredSize(of: photoView, nodeID: NodeID.legacyFile, maximumWidth: maximumContentWidth)
      primaryMediaWidth = size.width
      append(
        NodeID.legacyFile,
        size: size,
        spacing: 0
      )
    }
    if bubbleNodeViews[NodeID.photo] != nil {
      let size = measuredSize(of: newPhotoView, nodeID: NodeID.photo, maximumWidth: maximumContentWidth)
      primaryMediaWidth = max(primaryMediaWidth ?? 0, size.width)
      append(NodeID.photo, size: size, spacing: 0)
    }
    if bubbleNodeViews[NodeID.video] != nil {
      let size = measuredSize(of: videoView, nodeID: NodeID.video, maximumWidth: maximumContentWidth)
      primaryMediaWidth = max(primaryMediaWidth ?? 0, size.width)
      append(NodeID.video, size: size, spacing: 0)
    }
    if bubbleNodeViews[NodeID.voice] != nil {
      let availableWidth = max(1, maximumContentWidth - 24)
      append(
        NodeID.voice,
        size: CGSize(width: min(availableWidth, max(120, min(240, availableWidth))), height: 54),
        widthBehavior: .fill,
        insets: standardInsets
      )
    } else if bubbleNodeViews[NodeID.document] != nil {
      append(
        NodeID.document,
        size: measuredSize(of: documentView, nodeID: NodeID.document, maximumWidth: maximumContentWidth - 24),
        insets: standardInsets
      )
    }

    let attributedText = attributedMessageText() ?? NSAttributedString(string: "")
    let plainTextMaximumWidth = max(
      1,
      min(maximumContentWidth, primaryMediaWidth ?? maximumContentWidth) - 24
    )
    let textMeasurement: (size: CGSize, isSingleLine: Bool) = if let currentRichPlan {
      (currentRichPlan.size, false)
    } else {
      measureText(attributedText, maximumWidth: plainTextMaximumWidth)
    }
    if bubbleNodeViews[NodeID.text] != nil {
      append(
        NodeID.text,
        size: textMeasurement.size,
        insets: isEmojiOnlyMessage ? emojiInsets : standardInsets,
        spacing: hasFullBleedMedia ? 6 : nil
      )
    }

    for (index, attachment) in fullMessage.attachments.enumerated() {
      let externalTaskID = NodeID.externalTask(index, attachment.id)
      if let view = attachmentViews[externalTaskID] {
        var size = measuredSize(
          of: view,
          nodeID: externalTaskID,
          maximumWidth: maximumContentWidth - 24,
          fillsWidth: true
        )
        if size.height <= 1 { size.height = 76 }
        append(
          externalTaskID,
          size: size,
          widthBehavior: .fill,
          forcesMaximumWidth: true,
          insets: standardInsets
        )
      }
      let previewID = NodeID.urlPreview(index, attachment.id)
      if let view = attachmentViews[previewID] {
        let fillsWidth = attachment.urlPreview.map {
          URLPreviewView.preferredMode(for: $0, photoInfo: attachment.photoInfo) == .large
        } ?? false
        append(
          previewID,
          size: measuredSize(
            of: view,
            nodeID: previewID,
            maximumWidth: maximumContentWidth - 24,
            fillsWidth: fillsWidth
          ),
          widthBehavior: fillsWidth ? .fill : .natural,
          forcesMaximumWidth: fillsWidth,
          insets: standardInsets
        )
      }
    }

    let metadataSize = metadataView.intrinsicContentSize
    let reactionsSize: CGSize? = if fullMessage.reactions.isEmpty {
      nil
    } else {
      reactionsFlowView.measuredSizeV2(maximumWidth: max(1, maximumContentWidth - 24))
    }
    let externalReactions = reactionsAreExternal(in: fullMessage)
    let usesTextFooter = shouldUseTextFooterV2

    if bubbleNodeViews[NodeID.replyThreadSummary] != nil {
      append(
        NodeID.replyThreadSummary,
        size: measuredSize(
          of: replyThreadSummaryView,
          nodeID: NodeID.replyThreadSummary,
          maximumWidth: maximumContentWidth - 24,
          fillsWidth: true
        ),
        widthBehavior: .fill,
        insets: standardInsets
      )
    }

    if !usesTextFooter {
      if !externalReactions, let reactionsSize {
        append(
          NodeID.reactions,
          size: reactionsSize,
          insets: isEmojiOnlyMessage ? emojiInsets : standardInsets,
          spacing: isEmojiOnlyMessage ? 2 : nil
        )
      }
      if bubbleNodeViews[NodeID.metadata] != nil {
        append(
          NodeID.metadata,
          size: metadataSize,
          alignment: .trailing,
          insets: standardInsets
        )
      }
    }

    if bubbleNodeViews[NodeID.floatingMetadata] != nil {
      guard let targetID = floatingMetadataTargetV2 else { return nil }
      overlayNodes.append(.init(
        id: NodeID.floatingMetadata,
        targetID: targetID,
        size: measuredSize(
          of: floatingMetadataView,
          nodeID: NodeID.floatingMetadata,
          maximumWidth: maximumContentWidth
        ),
        anchor: .bottomTrailing,
        insets: floatingMetadataInsetsV2
      ))
    }

    let layoutTailSide: MessageBubbleLayoutInputV2.TailSide = switch tailSide {
      case .none: .none
      case .leading: .leading
      case .trailing: .trailing
    }

    let actionSize = rootNodeViews[NodeID.actions] != nil
      ? messageActionsSizeV2(maximumWidth: maximumContentWidth)
      : nil
    if rootNodeViews[NodeID.actions] != nil {
      belowBubbleNodes.append(.init(
        id: NodeID.actions,
        size: actionSize ?? .zero,
        spacingBefore: 4,
        widthBehavior: .fill
      ))
    }
    if externalReactions, let reactionsSize {
      belowBubbleNodes.append(.init(id: NodeID.reactions, size: reactionsSize, spacingBefore: 3))
    }
    let belowBubbleMinimumContentWidth = max(
      actionSize?.width ?? 0,
      externalReactions ? (reactionsSize?.width ?? 0) : 0
    )

    let lastIsFullBleedMedia = flowNodes.last.map {
      $0.id == NodeID.photo || $0.id == NodeID.video || $0.id == NodeID.legacyFile
    } ?? false
    let contentInsets = MessageLayoutInsetsV2(
      top: hasFullBleedMedia ? 0 : (isEmojiOnlyMessage ? 6 : 8),
      leading: 0,
      bottom: lastIsFullBleedMedia ? 0 : (isEmojiOnlyMessage ? 6 : 8),
      trailing: 0
    )
    let footer: MessageBubbleLayoutInputV2.Footer? = if usesTextFooter {
      .init(
        textNodeID: NodeID.text,
        metadataNodeID: NodeID.metadata,
        metadataSize: metadataSize,
        reactionsNodeID: externalReactions ? nil : reactionsSize.map { _ in NodeID.reactions },
        reactionsSize: externalReactions ? nil : reactionsSize,
        isTextSingleLine: textMeasurement.isSingleLine,
        isRTL: textIsRTLV2,
        trailingTextLine: currentRichPlan?.trailingTextLine.map {
          .init(usedWidth: $0.usedWidth, height: $0.height, isRTL: $0.isRTL)
        },
        horizontalSpacing: 5,
        verticalSpacing: 4
      )
    } else {
      nil
    }

    return MessageBubbleLayoutPlannerV2.layout(.init(
      containerWidth: containerWidth,
      maximumBubbleWidth: maximumWidth,
      minimumBubbleWidth: min(
        maximumWidth,
        belowBubbleMinimumContentWidth
          + (belowBubbleMinimumContentWidth > 0 ? tailWidth : 0)
      ),
      minimumBubbleHeight: MessageBubbleView.minimumBodyHeight,
      alignment: outgoing ? .trailing : .leading,
      tailSide: layoutTailSide,
      tailWidth: tailWidth,
      contentInsets: contentInsets,
      flowNodes: flowNodes,
      footer: footer,
      overlayNodes: overlayNodes,
      belowBubbleNodes: belowBubbleNodes
    ))
  }

  private var resolvedTailSide: MessageBubbleTailSide {
    bubbleView.side
  }

  private func layoutCacheKey(containerWidth: CGFloat) -> NSString {
    let scale = max(traitCollection.displayScale, 1)
    let widthPixels = Int((containerWidth * scale).rounded())
    let maximumWidthPixels = Int((maximumBubbleWidth * scale).rounded())
    return [
      String(message.stableId),
      String(layoutContentSignature),
      String(widthPixels),
      String(maximumWidthPixels),
      String(describing: displayMode),
      outgoing ? "outgoing" : "incoming",
      theme.preset.rawValue,
      theme.variant.rawValue,
      traitCollection.preferredContentSizeCategory.rawValue,
      String(traitCollection.layoutDirection.rawValue),
      String(describing: resolvedTailSide),
      disclosureOverridesCacheKey,
    ].joined(separator: "|") as NSString
  }

  private var disclosureOverridesCacheKey: String {
    RichBlockDisclosureStateStoreV2.shared.overrides(for: message)
      .map { "\($0.key.components)=\($0.value)" }
      .sorted()
      .joined(separator: ",")
  }

  private func ensureRichPlan(containerWidth: CGFloat) -> Bool {
    guard shouldRenderRichContentV2,
          let payload = message.blockContentPayload
    else {
      currentRichPlan = nil
      return true
    }
    let tailWidth = MessageBubbleView.tailWidth(for: resolvedTailSide)
    let maximumWidth = min(containerWidth, maximumBubbleWidth + tailWidth)
    let availableWidth = max(1, maximumWidth - tailWidth - 24)
    let attributedText = attributedMessageText() ?? NSAttributedString(string: message.text ?? "")
    guard let plan = RichBlockLayoutPlannerV2.shared.plan(
      content: payload.content,
      contentCacheSignature: payload.cacheSignature,
      contentByteCount: payload.byteCount,
      attributedText: attributedText,
      availableWidth: availableWidth,
      baseFontSize: richBaseFontSize,
      disclosureOverrides: RichBlockDisclosureStateStoreV2.shared.overrides(for: message)
    ) else {
      currentRichPlan = nil
      return true
    }

    if currentRichPlan != plan
      || renderedRichContentSignature != payload.cacheSignature
      || renderedRichContentByteCount != payload.byteCount
      || renderedRichTextHash != attributedText.hash
    {
      richContentView.update(
        plan: plan,
        content: payload.content,
        attributedText: attributedText,
        baseFontSize: richBaseFontSize,
        palette: richPalette,
        message: message,
        deferLayout: transitionOldRichPlan != nil,
        transitionGeneration: geometryTransitionGeneration
      )
      renderedRichContentSignature = payload.cacheSignature
      renderedRichContentByteCount = payload.byteCount
      renderedRichTextHash = attributedText.hash
    }
    currentRichPlan = plan
    return true
  }

  private var richPalette: RichBlockPaletteV2 {
    RichBlockPaletteV2(
      primary: textColor,
      secondary: MessageRichTextRenderer.secondaryColor(for: outgoing),
      accent: MessageRichTextRenderer.linkColor(for: outgoing),
      subtleFill: textColor.withAlphaComponent(0.045),
      codeFill: textColor.withAlphaComponent(0.065),
      separator: textColor.withAlphaComponent(0.14),
      placeholder: textColor.withAlphaComponent(0.075)
    )
  }

  private var richBaseFontSize: CGFloat {
    UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: traitCollection)
  }

  private var shouldUseTextFooterV2: Bool {
    message.hasText
      && fullMessage.file == nil
      && fullMessage.photoInfo == nil
      && fullMessage.videoInfo == nil
      && fullMessage.documentInfo == nil
      && !shouldShowVoiceMessage
      && attachmentViews.isEmpty
      && message.repliedToMessageId == nil
      && !shouldShowForwardHeader
      && !shouldShowReplyThreadSummary
      && !hasMessageActionRowsV2
      && !isEmojiOnlyMessage
      && fullMessage.displayText?.containsEmoji != true
      && (fullMessage.reactions.isEmpty || shouldShareReactionsWithMetadataV2)
  }

  private var shouldShareReactionsWithMetadataV2: Bool {
    guard fullMessage.groupedReactions.count == 1,
          let group = fullMessage.groupedReactions.first
    else { return false }
    return group.reactions.count <= 3
  }

  private var shouldRenderRichContentV2: Bool {
    message.blockContentPayload != nil && fullMessage.translationText == nil
  }

  private var floatingMetadataTargetV2: MessageLayoutNodeIDV2? {
    if isEmojiOnlyMessage, message.hasText {
      return NodeID.text
    }
    if isSticker {
      if fullMessage.file != nil { return NodeID.legacyFile }
      if fullMessage.photoInfo != nil { return NodeID.photo }
      if fullMessage.videoInfo != nil { return NodeID.video }
    }
    guard shouldShowFloatingMetadata else { return nil }
    if fullMessage.photoInfo != nil { return NodeID.photo }
    if fullMessage.videoInfo != nil { return NodeID.video }
    return nil
  }

  private var floatingMetadataInsetsV2: MessageLayoutInsetsV2 {
    if isEmojiOnlyMessage {
      return .init(top: 0, leading: 0, bottom: 4, trailing: 4)
    }
    if isSticker {
      return .init(top: 0, leading: 0, bottom: 8, trailing: 8)
    }
    return .init(top: 0, leading: 0, bottom: 10, trailing: 12)
  }

  private func updateForwardAndReplyContent() {
    if bubbleNodeViews[NodeID.forwardHeader] != nil {
      forwardHeaderLabel.textColor = forwardHeaderTextColor
      forwardHeaderLabel.text = forwardHeaderText
      invalidateLeafMeasurement(NodeID.forwardHeader)
    }

    guard bubbleNodeViews[NodeID.reply] != nil else { return }
    if let embeddedMessage = fullMessage.repliedToMessage {
      embedView.configure(
        embeddedMessage: embeddedMessage,
        kind: .replyInMessage,
        outgoing: outgoing,
        isOnlyEmoji: isEmojiOnlyMessage,
        thumbnailReloadMessage: fullMessage.message
      )
    } else {
      embedView.showNotLoaded(
        kind: .replyInMessage,
        outgoing: outgoing,
        isOnlyEmoji: isEmojiOnlyMessage
      )
      ensureRepliedMessageCachedOnce()
    }
  }

  private func updateReplyThreadSummaryContent() {
    guard let summary = message.replyThreadSummary else { return }
    replyThreadSummaryView.configure(
      replyCount: Int(summary.replyCount),
      recentAuthors: recentReplyThreadAuthors(),
      hasUnread: summary.hasUnread_p,
      outgoing: shouldUseWhiteReplyThreadSummary,
      title: fullMessage.replyThreadCustomTitle
    )
  }

  private func configureReplyThreadSummaryV2() {
    updateReplyThreadSummaryContent()
    replyThreadSummaryView.onTap = { [weak self] in
      guard let self else { return }
      ReplyThreadNavigator.open(message: message, source: .summary) { [weak self] loading in
        self?.replyThreadSummaryView.setLoading(loading)
      }
    }
    replyThreadSummaryView.contextMenuProvider = { [weak self] in
      self?.makeReplyThreadSummaryMenu()
    }
  }

  private func updateRetainedContentViews(from previousMessage: FullMessage, to updatedMessage: FullMessage) {
    if bubbleNodeViews[NodeID.legacyFile] != nil,
       previousMessage.file != updatedMessage.file
    {
      photoView.update(with: updatedMessage)
      invalidateLeafMeasurement(NodeID.legacyFile)
    }
    if bubbleNodeViews[NodeID.photo] != nil,
       previousMessage.photoInfo != updatedMessage.photoInfo
       || previousMessage.message.fileId != updatedMessage.message.fileId
       || previousMessage.message.photoId != updatedMessage.message.photoId
    {
      newPhotoView.update(with: updatedMessage)
      invalidateLeafMeasurement(NodeID.photo)
    }
    if bubbleNodeViews[NodeID.video] != nil,
       previousMessage.videoInfo != updatedMessage.videoInfo
       || previousMessage.message.videoId != updatedMessage.message.videoId
    {
      videoView.update(with: updatedMessage)
      invalidateLeafMeasurement(NodeID.video)
    }
    if bubbleNodeViews[NodeID.document] != nil,
       previousMessage.documentInfo != updatedMessage.documentInfo
    {
      documentView.update(with: updatedMessage, outgoing: outgoing)
      invalidateLeafMeasurement(NodeID.document)
    }
    if bubbleNodeViews[NodeID.voice] != nil,
       previousMessage.message.voiceContent != updatedMessage.message.voiceContent
    {
      voiceMessageViewController.rootView = VoiceMessageBubble(
        message: updatedMessage.message,
        outgoing: outgoing
      )
    }

    for (index, attachment) in updatedMessage.attachments.enumerated() {
      guard previousMessage.attachments.indices.contains(index),
            previousMessage.attachments[index] != attachment
      else { continue }
      let externalID = NodeID.externalTask(index, attachment.id)
      if let view = attachmentViews[externalID] as? MessageAttachmentEmbed,
         let externalTask = attachment.externalTask,
         let userInfo = attachment.userInfo
      {
        view.configure(
          userInfo: userInfo,
          outgoing: outgoing,
          url: URL(string: externalTask.url ?? ""),
          issueIdentifier: nil,
          title: externalTask.title,
          externalTask: externalTask,
          messageId: updatedMessage.message.messageId,
          chatId: updatedMessage.message.chatId
        )
        invalidateLeafMeasurement(externalID)
      }
      let previewID = NodeID.urlPreview(index, attachment.id)
      if let view = attachmentViews[previewID] as? URLPreviewView {
        configureURLPreviewView(view, for: attachment)
        invalidateLeafMeasurement(previewID)
      }
    }
  }

  private func forwardProjectionChanged(from previous: FullMessage, to updated: FullMessage) -> Bool {
    previous.forwardFromUserInfo != updated.forwardFromUserInfo
      || previous.forwardFromPeerUserInfo != updated.forwardFromPeerUserInfo
      || previous.forwardFromChatInfo != updated.forwardFromChatInfo
      || previous.message.forwardFromUserId != updated.message.forwardFromUserId
      || previous.message.forwardFromPeerUserId != updated.message.forwardFromPeerUserId
      || previous.message.forwardFromPeerThreadId != updated.message.forwardFromPeerThreadId
  }

  private func replyProjectionChanged(from previous: FullMessage, to updated: FullMessage) -> Bool {
    previous.repliedToMessage != updated.repliedToMessage
  }

  private func replyThreadProjectionChanged(from previous: FullMessage, to updated: FullMessage) -> Bool {
    previous.message.replyThreadSummary != updated.message.replyThreadSummary
      || previous.replyThread != updated.replyThread
  }

  private func reconcileRetainedNodePlacement(from previousMessage: FullMessage) {
    reconcileForwardAndReplyNodes()
    reconcileMediaNodes()
    reconcileAttachmentNodes()
    reconcileActionNodes(from: previousMessage)

    let wantsRich = shouldRenderRichContentV2
    let hasRich = bubbleNodeViews[NodeID.text] === richContentView
    if wantsRich != hasRich {
      if let old = bubbleNodeViews.removeValue(forKey: NodeID.text) {
        removeWithTransition(old)
      }
      if wantsRich {
        installRichInteractionsIfNeeded()
        registerBubbleNode(richContentView, id: NodeID.text)
        messageLabel.alpha = 0
        messageLabel.isUserInteractionEnabled = false
        if messageLabel.superview !== bubbleView.contentView {
          bubbleView.contentView.addSubview(messageLabel)
        }
        markAppearing(richContentView)
      } else {
        richContentView.prepareForReuse()
        messageLabel.alpha = 1
        messageLabel.isUserInteractionEnabled = true
        if message.hasText {
          registerBubbleNode(messageLabel, id: NodeID.text)
          markAppearing(messageLabel)
        }
      }
    } else if !wantsRich {
      let wantsText = message.hasText
      let hasText = bubbleNodeViews[NodeID.text] === messageLabel
      if wantsText != hasText {
        if wantsText {
          registerBubbleNode(messageLabel, id: NodeID.text)
          markAppearing(messageLabel)
        } else if let old = bubbleNodeViews.removeValue(forKey: NodeID.text) {
          removeWithTransition(old)
        }
      }
    }

    let reactionsShouldBeExternal = reactionsAreExternal(in: fullMessage)
    let reactionsAreRoot = rootNodeViews[NodeID.reactions] === reactionsFlowView
    if reactionsShouldBeExternal != reactionsAreRoot {
      retainTransitionSnapshot(of: reactionsFlowView)
      bubbleNodeViews.removeValue(forKey: NodeID.reactions)
      rootNodeViews.removeValue(forKey: NodeID.reactions)
      if reactionsShouldBeExternal {
        registerRootNode(reactionsFlowView, id: NodeID.reactions)
      } else {
        registerBubbleNode(reactionsFlowView, id: NodeID.reactions)
      }
      markAppearing(reactionsFlowView, scale: 0.96)
    }

    let wantsFloating = floatingMetadataTargetV2 != nil
    let hasFloating = bubbleNodeViews[NodeID.floatingMetadata] === floatingMetadataView
    if wantsFloating != hasFloating {
      if let old = bubbleNodeViews.removeValue(forKey: NodeID.floatingMetadata) {
        removeWithTransition(old)
      }
      if let old = bubbleNodeViews.removeValue(forKey: NodeID.metadata) {
        removeWithTransition(old)
      }
      let appearing: UIView
      if wantsFloating {
        registerBubbleNode(floatingMetadataView, id: NodeID.floatingMetadata)
        appearing = floatingMetadataView
      } else {
        registerBubbleNode(metadataView, id: NodeID.metadata)
        appearing = metadataView
      }
      markAppearing(appearing, scale: 0.96)
    }

    let wantsThreadSummary = shouldShowReplyThreadSummary && message.replyThreadSummary != nil
    let hasThreadSummary = bubbleNodeViews[NodeID.replyThreadSummary] === replyThreadSummaryView
    if wantsThreadSummary != hasThreadSummary {
      if wantsThreadSummary {
        registerBubbleNode(replyThreadSummaryView, id: NodeID.replyThreadSummary)
        configureReplyThreadSummaryV2()
        markAppearing(replyThreadSummaryView)
      } else if let old = bubbleNodeViews.removeValue(forKey: NodeID.replyThreadSummary) {
        removeWithTransition(old)
      }
    }
  }

  private func reconcileForwardAndReplyNodes() {
    let wantsForward = shouldShowForwardHeader
    let hasForward = bubbleNodeViews[NodeID.forwardHeader] === forwardHeaderLabel
    if wantsForward != hasForward {
      if wantsForward {
        forwardHeaderLabel.textColor = forwardHeaderTextColor
        forwardHeaderLabel.text = forwardHeaderText
        registerBubbleNode(forwardHeaderLabel, id: NodeID.forwardHeader)
        markAppearing(forwardHeaderLabel)
      } else if let old = bubbleNodeViews.removeValue(forKey: NodeID.forwardHeader) {
        removeWithTransition(old)
      }
      invalidateLeafMeasurement(NodeID.forwardHeader)
    }

    let wantsReply = message.repliedToMessageId != nil
    let hasReply = bubbleNodeViews[NodeID.reply] === embedView
    if wantsReply != hasReply {
      if wantsReply {
        installReplyTapIfNeeded()
        registerBubbleNode(embedView, id: NodeID.reply)
        updateForwardAndReplyContent()
        markAppearing(embedView)
      } else if let old = bubbleNodeViews.removeValue(forKey: NodeID.reply) {
        removeWithTransition(old)
      }
    }
  }

  private func reconcileMediaNodes() {
    reconcileBubbleNode(NodeID.legacyFile, wants: fullMessage.file != nil) {
      photoView.update(with: fullMessage)
      return photoView
    }
    reconcileBubbleNode(NodeID.photo, wants: fullMessage.photoInfo != nil) {
      newPhotoView.update(with: fullMessage)
      bindPhotoTapHandlerIfNeeded()
      return newPhotoView
    }
    reconcileBubbleNode(NodeID.video, wants: fullMessage.videoInfo != nil) {
      videoView.update(with: fullMessage)
      return videoView
    }
    reconcileBubbleNode(NodeID.voice, wants: shouldShowVoiceMessage) {
      voiceMessageViewController.rootView = VoiceMessageBubble(message: message, outgoing: outgoing)
      return voiceMessageViewController.view
    }
    reconcileBubbleNode(
      NodeID.document,
      wants: !shouldShowVoiceMessage && fullMessage.documentInfo != nil
    ) {
      documentView.update(with: fullMessage, outgoing: outgoing)
      return documentView
    }
  }

  private func reconcileAttachmentNodes() {
    var desired: [MessageLayoutNodeIDV2: FullAttachment] = [:]
    for (index, attachment) in fullMessage.attachments.enumerated() {
      if attachment.externalTask != nil, attachment.userInfo != nil {
        desired[NodeID.externalTask(index, attachment.id)] = attachment
      }
      if attachment.urlPreview != nil {
        desired[NodeID.urlPreview(index, attachment.id)] = attachment
      }
    }

    for id in Array(attachmentViews.keys) where desired[id] == nil {
      attachmentViews.removeValue(forKey: id)
      if let old = bubbleNodeViews.removeValue(forKey: id) {
        removeWithTransition(old)
      }
      invalidateLeafMeasurement(id)
    }

    for (id, attachment) in desired where attachmentViews[id] == nil {
      let view: UIView
      if let externalTask = attachment.externalTask, let userInfo = attachment.userInfo {
        let embed = MessageAttachmentEmbed()
        embed.configure(
          userInfo: userInfo,
          outgoing: outgoing,
          url: URL(string: externalTask.url ?? ""),
          issueIdentifier: nil,
          title: externalTask.title,
          externalTask: externalTask,
          messageId: message.messageId,
          chatId: message.chatId
        )
        view = embed
      } else {
        view = createURLPreviewView(for: attachment)
      }
      attachmentViews[id] = view
      registerBubbleNode(view, id: id)
      markAppearing(view)
      invalidateLeafMeasurement(id)
    }
  }

  private func reconcileActionNodes(from previousMessage: FullMessage) {
    let oldTopology = messageActionTopology(in: previousMessage)
    let newTopology = messageActionTopology(in: fullMessage)
    guard oldTopology != newTopology else { return }
    let hadActions = rootNodeViews[NodeID.actions] === messageActionsContainer
    if hadActions {
      retainTransitionSnapshot(of: messageActionsContainer)
    }
    if newTopology.isEmpty {
      rootNodeViews.removeValue(forKey: NodeID.actions)
      messageActionsContainer.removeFromSuperview()
      return
    }
    setupMessageActionsV2()
    registerRootNode(messageActionsContainer, id: NodeID.actions)
    markAppearing(messageActionsContainer)
  }

  private func reconcileBubbleNode(
    _ id: MessageLayoutNodeIDV2,
    wants: Bool,
    makeView: () -> UIView
  ) {
    let existing = bubbleNodeViews[id]
    guard wants != (existing != nil) else { return }
    invalidateLeafMeasurement(id)
    if wants {
      let view = makeView()
      registerBubbleNode(view, id: id)
      markAppearing(view)
    } else if let existing {
      bubbleNodeViews.removeValue(forKey: id)
      removeWithTransition(existing)
    }
  }

  private func installReplyTapIfNeeded() {
    guard !didInstallReplyTap else { return }
    didInstallReplyTap = true
    embedView.isUserInteractionEnabled = true
    embedView.addGestureRecognizer(UITapGestureRecognizer(
      target: self,
      action: #selector(handleEmbedViewTap)
    ))
  }

  private func installRichInteractionsIfNeeded() {
    guard !didInstallRichInteractions else { return }
    didInstallRichInteractions = true
    richContentView.onDisclosureToggle = { [weak self] path, expanded in
      self?.toggleDisclosure(path: path, expanded: expanded)
    }
    richContentView.onEntityTap = { [weak self] text, character in
      self?.handleRichEntityTap(text: text, characterIndex: character)
    }
    richContentView.onImageTap = { [weak self] selection in
      self?.openRichImages(selection)
    }
    let richLongPress = UILongPressGestureRecognizer(
      target: self,
      action: #selector(handleRichLinkLongPress(_:))
    )
    richLongPress.delegate = self
    richContentView.addGestureRecognizer(richLongPress)
    richLinkLongPress = richLongPress
  }

  private func markAppearing(_ view: UIView, scale: CGFloat = 0.98) {
    view.alpha = 0
    view.transform = CGAffineTransform(scaleX: scale, y: scale)
    transitionAppearingViews.append(view)
  }

  private func removeWithTransition(_ view: UIView) {
    retainTransitionSnapshot(of: view)
    view.removeFromSuperview()
  }

  private func retainTransitionSnapshot(of view: UIView) {
    let frame: CGRect = if let presentation = view.layer.presentation(),
                           let parent = view.superview
    {
      parent.convert(presentation.frame, to: self)
    } else {
      view.convert(view.bounds, to: self)
    }
    if let snapshot = view.snapshotView(afterScreenUpdates: false), frame.isFiniteAndVisible {
      snapshot.frame = frame
      snapshot.isUserInteractionEnabled = false
      addSubview(snapshot)
      transitionDisappearingSnapshots.append(.init(
        generation: geometryTransitionGeneration,
        view: snapshot
      ))
    }
  }

  private func setupMessageActionsV2() {
    messageActionButtonsById.removeAll(keepingCapacity: true)
    actionButtonRows.removeAll(keepingCapacity: true)
    for subview in messageActionsContainer.subviews {
      if let stack = subview as? UIStackView, messageActionsContainer.arrangedSubviews.contains(stack) {
        messageActionsContainer.removeArrangedSubview(stack)
      }
      subview.removeFromSuperview()
    }

    for row in filteredMessageActionRows(in: fullMessage) {
      let buttons = row.map { action in
        let button = createMessageActionButton(for: action)
        button.useMessageView2Presentation()
        button.translatesAutoresizingMaskIntoConstraints = true
        messageActionsContainer.addSubview(button)
        messageActionButtonsById[button.actionId] = button
        return button
      }
      if !buttons.isEmpty { actionButtonRows.append(buttons) }
    }
    setupMessageActionStateSubscriptions()
    updateMessageActionButtonsLoadingState()
  }

  private func updateMessageActionsContent(with updatedMessage: FullMessage) {
    let rows = filteredMessageActionRows(in: updatedMessage)
    guard rows.count == actionButtonRows.count else { return }
    messageActionButtonsById.removeAll(keepingCapacity: true)
    for (actions, buttons) in zip(rows, actionButtonRows) {
      guard actions.count == buttons.count else { continue }
      for (action, button) in zip(actions, buttons) {
        button.configure(action: action, outgoing: outgoing)
        button.useMessageView2Presentation()
        messageActionButtonsById[button.actionId] = button
      }
    }
    updateMessageActionButtonsLoadingState()
  }

  private func messageActionsSizeV2(maximumWidth: CGFloat) -> CGSize {
    guard !actionButtonRows.isEmpty else { return .zero }
    let naturalWidth = actionButtonRows.reduce(CGFloat.zero) { rowMaximum, buttons in
      let rowWidth = buttons.reduce(CGFloat.zero) { partial, button in
        partial + max(110, button.intrinsicContentSize.width)
      } + CGFloat(max(0, buttons.count - 1)) * 4
      return max(rowMaximum, rowWidth)
    }
    let rowHeight: CGFloat = 36
    return CGSize(
      width: min(maximumWidth, max(180, naturalWidth)),
      height: CGFloat(actionButtonRows.count) * rowHeight + CGFloat(max(0, actionButtonRows.count - 1)) * 4
    )
  }

  private func layoutMessageActionButtons(in bounds: CGRect) {
    guard !actionButtonRows.isEmpty else { return }
    let spacing: CGFloat = 4
    let rowHeight = max(
      1,
      (bounds.height - CGFloat(max(0, actionButtonRows.count - 1)) * spacing)
        / CGFloat(actionButtonRows.count)
    )
    for (rowIndex, buttons) in actionButtonRows.enumerated() {
      let availableWidth = bounds.width - CGFloat(max(0, buttons.count - 1)) * spacing
      let buttonWidth = max(1, availableWidth / CGFloat(buttons.count))
      let y = CGFloat(rowIndex) * (rowHeight + spacing)
      for (column, button) in buttons.enumerated() {
        button.frame = CGRect(
          x: CGFloat(column) * (buttonWidth + spacing),
          y: y,
          width: buttonWidth,
          height: rowHeight
        )
      }
    }
  }

  private func filteredMessageActionRows(in fullMessage: FullMessage) -> [[InlineProtocol.MessageAction]] {
    guard let actions = fullMessage.message.actions else { return [] }
    return actions.rows.compactMap { row in
      let filtered = row.actions.filter { action in
        !action.actionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && !action.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && action.action != nil
      }
      return filtered.isEmpty ? nil : filtered
    }
  }

  private var hasMessageActionRowsV2: Bool {
    !filteredMessageActionRows(in: fullMessage).isEmpty
  }

  private func messageActionTopology(in fullMessage: FullMessage) -> [[String]] {
    filteredMessageActionRows(in: fullMessage).map { $0.map(\.actionID) }
  }

  private func toggleDisclosure(path: BlockContentPath, expanded: Bool) {
    let width = bounds.width > 0 ? bounds.width : maximumBubbleWidth
    let oldLayout = measuredLayout(containerWidth: width)
    transitionOldRichPlan = currentRichPlan
    geometryTransitionGeneration &+= 1
    RichBlockDisclosureStateStoreV2.shared.set(expanded, path: path, message: message)
    currentLayout = nil
    currentLayoutKey = nil
    currentRichPlan = nil
    invalidateIntrinsicContentSize()
    setNeedsLayout()
    guard let oldLayout, let newLayout = measuredLayout(containerWidth: width) else { return }
    onGeometryChange?(oldLayout, newLayout)
  }

  private func handleRichEntityTap(text: NSAttributedString, characterIndex: Int) {
    guard characterIndex >= 0, characterIndex < text.length else { return }
    if let userID = text.attribute(.mentionUserId, at: characterIndex, effectiveRange: nil) as? Int64 {
      if let agentID = text.attribute(.mentionAgentId, at: characterIndex, effectiveRange: nil) as? Int64 {
        Task { @MainActor in
          guard !(await BotAgentMentionNavigator.open(
            agentId: agentID,
            botUserId: userID,
            peer: message.peerId
          )) else { return }
          NotificationCenter.default.post(
            name: Notification.Name("MentionTapped"),
            object: nil,
            userInfo: ["userId": userID]
          )
        }
        return
      }
      NotificationCenter.default.post(
        name: Notification.Name("MentionTapped"),
        object: nil,
        userInfo: ["userId": userID]
      )
      return
    }
    if let groupID = text.attribute(.mentionGroupId, at: characterIndex, effectiveRange: nil) as? Int64 {
      NotificationCenter.default.post(
        name: .userGroupMentionTapped,
        object: nil,
        userInfo: ["target": UserGroupMentionTarget(groupId: groupID, spaceId: spaceId)]
      )
      return
    }
    if let thread = text.attribute(.threadLink, at: characterIndex, effectiveRange: nil) as? ThreadLinkTarget {
      ThreadLinkNavigator.open(target: thread)
      return
    }

    var effectiveRange = NSRange(location: 0, length: 0)
    if let inlineCode = text.attribute(
      .inlineCode,
      at: characterIndex,
      effectiveRange: &effectiveRange
    ) as? Bool, inlineCode {
      UIPasteboard.general.string = (text.string as NSString).substring(with: effectiveRange)
      ToastManager.shared.showToast("Copied code", type: .success, systemImage: "doc.on.doc")
      return
    }
    if let command = text.attribute(
      .botCommand,
      at: characterIndex,
      effectiveRange: &effectiveRange
    ) as? String {
      sendBotCommand(command.isEmpty ? (text.string as NSString).substring(with: effectiveRange) : command)
      return
    }
    if let email = text.attribute(.emailAddress, at: characterIndex, effectiveRange: nil) as? String {
      UIPasteboard.general.string = email
      ToastManager.shared.showToast("Copied email", type: .success, systemImage: "doc.on.doc")
      return
    }
    if let phone = text.attribute(.phoneNumber, at: characterIndex, effectiveRange: nil) as? String {
      UIPasteboard.general.string = phone
      ToastManager.shared.showToast("Copied number", type: .success, systemImage: "doc.on.doc")
      return
    }
    if let url = linkURL(at: characterIndex, in: text) {
      linkTapHandler?(url)
    }
  }

  @objc private func handleRichLinkLongPress(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began else { return }
    let point = gesture.location(in: richContentView)
    guard let hit = richContentView.entityHit(at: point),
          let url = linkURL(at: hit.characterIndex, in: hit.text)
    else { return }
    presentLinkActionSheet(
      url: url,
      sourceView: richContentView,
      sourceRect: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)
    )
  }

  private func richImageURL(for photo: PhotoInfo) -> URL? {
    guard let size = photo.bestPhotoSize() else { return nil }
    return if let localPath = size.localPath, !localPath.isEmpty {
      FileCache.getUrl(for: .photos, localPath: localPath)
    } else if let cdnURL = size.cdnUrl {
      URL(string: cdnURL)
    } else {
      nil
    }
  }

  private func openRichImages(_ selection: RichBlockImageGallerySelectionV2) {
    let selectedPhoto = selection.photos.indices.contains(selection.initialIndex)
      ? selection.photos[selection.initialIndex]
      : selection.photos.first
    guard let selectedPhoto else { return }

    var seenPhotoIDs: Set<Int64> = []
    var galleryPhotos = currentRichPlan?.nodes.flatMap { node -> [PhotoInfo] in
      switch node.kind {
        case let .image(image):
          if case let .ready(photo) = image.state { return [photo] }
          return []
        case let .album(album):
          return album.items.compactMap { item in
            if case let .ready(photo) = item.state { return photo }
            return nil
          }
        default:
          return []
      }
    }.filter { seenPhotoIDs.insert($0.id).inserted } ?? []
    if !seenPhotoIDs.contains(selectedPhoto.id) {
      galleryPhotos.append(selectedPhoto)
    }

    let resolved = galleryPhotos.compactMap { photo -> (Int64, ImageViewerItem)? in
      guard let url = richImageURL(for: photo) else { return nil }
      return (photo.id, ImageViewerItem(id: photo.id, url: url))
    }
    guard !resolved.isEmpty,
          let viewController = findViewController(),
          viewController.presentedViewController == nil
    else { return }
    let initialIndex = resolved.firstIndex { $0.0 == selectedPhoto.id } ?? 0
    let viewer = ImageViewerController(
      imageItems: resolved.map(\.1),
      initialIndex: initialIndex,
      sourceView: selection.sourceView,
      sourceImage: selection.sourceImage,
      sourceCornerRadius: 7,
      sourceViewProvider: { [weak richContentView = self.richContentView] photoID in
        richContentView?.sourceView(forRichPhotoID: photoID)
      }
    )
    viewController.present(viewer, animated: false)
  }

  private func invalidateMeasuredContent() {
    currentLayout = nil
    currentLayoutKey = nil
    currentRichPlan = nil
    invalidateIntrinsicContentSize()
    setNeedsLayout()
  }

  private func measureText(
    _ attributedText: NSAttributedString,
    maximumWidth: CGFloat
  ) -> (size: CGSize, isSingleLine: Bool) {
    guard attributedText.length > 0 else { return (.zero, false) }
    let width = max(1, maximumWidth)
    let unbounded = attributedText.boundingRect(
      with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    ).integral.size
    let measured = attributedText.boundingRect(
      with: CGSize(width: min(width, max(1, ceil(unbounded.width))), height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    ).integral.size
    return (
      CGSize(width: max(1, ceil(measured.width)), height: max(1, ceil(measured.height))),
      !attributedText.string.contains("\n") && unbounded.width <= width + 0.5
    )
  }

  private var textIsRTLV2: Bool {
    guard let text = fullMessage.displayText else { return false }
    for scalar in text.unicodeScalars {
      switch scalar.value {
        case 0x0590 ... 0x08FF, 0xFB1D ... 0xFDFF, 0xFE70 ... 0xFEFF:
          return true
        case 0x0041 ... 0x005A, 0x0061 ... 0x007A, 0x00C0 ... 0x02AF:
          return false
        default:
          continue
      }
    }
    return false
  }

  private func measuredSize(
    of view: UIView,
    nodeID: MessageLayoutNodeIDV2,
    maximumWidth: CGFloat,
    fillsWidth: Bool = false
  ) -> CGSize {
    let width = max(1, maximumWidth)
    let scale = max(traitCollection.displayScale, 1)
    let key = LeafMeasurementKey(
      nodeID: nodeID,
      widthPixels: Int((width * scale).rounded()),
      generation: leafMeasurementGenerations[nodeID, default: 0],
      fillsWidth: fillsWidth,
      contentSizeCategory: traitCollection.preferredContentSizeCategory,
      layoutDirection: traitCollection.layoutDirection.rawValue
    )
    if let cached = leafMeasurements[key] { return cached }
    let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
    let oldBounds = view.bounds
    view.bounds = CGRect(origin: oldBounds.origin, size: CGSize(width: width, height: max(1, oldBounds.height)))
    view.setNeedsLayout()
    view.layoutIfNeeded()
    var result = view.systemLayoutSizeFitting(
      target,
      withHorizontalFittingPriority: fillsWidth ? .required : .fittingSizeLevel,
      verticalFittingPriority: .fittingSizeLevel
    )
    if !result.width.isFinite || result.width <= 0 || !result.height.isFinite || result.height <= 0 {
      result = view.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
    }
    if !result.width.isFinite || result.width <= 0 {
      let intrinsicWidth = view.intrinsicContentSize.width
      result.width = intrinsicWidth.isFinite && intrinsicWidth > 0 ? intrinsicWidth : width
    }
    if !result.height.isFinite || result.height <= 0 {
      let intrinsicHeight = view.intrinsicContentSize.height
      result.height = intrinsicHeight.isFinite && intrinsicHeight > 0 ? intrinsicHeight : 1
    }
    view.bounds = oldBounds
    let measured = CGSize(
      width: fillsWidth ? width : min(width, ceil(result.width)),
      height: ceil(result.height)
    )
    if leafMeasurements.count >= 128 {
      leafMeasurements.removeAll(keepingCapacity: true)
    }
    leafMeasurements[key] = measured
    return measured
  }

  private func invalidateLeafMeasurement(_ nodeID: MessageLayoutNodeIDV2) {
    leafMeasurementGenerations[nodeID, default: 0] += 1
  }

  private func convertToBubbleContent(_ frame: CGRect) -> CGRect {
    let contentOrigin = bubbleView.contentView.convert(CGPoint.zero, to: self)
    return frame.offsetBy(dx: -contentOrigin.x, dy: -contentOrigin.y)
  }

  private func reactionsAreExternal(in fullMessage: FullMessage) -> Bool {
    let message = fullMessage.message
    let hasMedia = message.hasPhoto || message.hasVideo
    return (hasMedia || message.isSticker == true)
      && !message.hasText
      && !fullMessage.reactions.isEmpty
  }
}
