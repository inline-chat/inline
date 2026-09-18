import Auth
import Combine
import ContextMenuAccessoryStructs
import GRDB
import InlineIOSUI
import InlineKit
import InlineTheme
import InlineUI
import Logger
import Nuke
import NukeUI
import Photos
import SwiftUI
import TextProcessing
import Translation
import UIKit

final class MessagesCollectionView: UICollectionView {
  struct ScrollAffordanceState: Equatable {
    var isVisible = false
    var hasUnread = false
  }

  private enum ScrollAffordanceMetrics {
    static let showDistance: CGFloat = 44
    static let hideDistance: CGFloat = 12
    static let unreadBottomDistance: CGFloat = 12
    static let scrollabilityTolerance: CGFloat = 1
  }

  private let peerId: Peer
  private var chatId: Int64
  private var spaceId: Int64?
  private let isPreview: Bool
  private var theme: IOSThemeSnapshot
  private var coordinator: Coordinator
  private var isContextMenuOpen = false
  private var lastKnownNavBarHeight: CGFloat = 0
  private var needsContentInsetUpdateAfterContextMenu = false
  private var pendingScrollMessageID: Int64?
  private var pendingScrollLoadTask: Task<Void, Never>?
  private var messageFocusRevision: UInt64 = 0
  private let sendAnimationScrollState = SendMessageAnimationScrollState()
  private var scrollAffordanceState = ScrollAffordanceState()
  private var scrollAffordanceUpdateDepth = 0

  var onScrollAffordanceChanged: ((ScrollAffordanceState) -> Void)? {
    didSet {
      onScrollAffordanceChanged?(scrollAffordanceState)
    }
  }

  init(
    peerId: Peer,
    chatId: Int64,
    spaceId: Int64?,
    collapsedMaxId: Int64? = nil,
    isPreview: Bool = false,
    sendAnimationCoordinator: SendMessageAnimationCoordinator? = nil,
    theme: IOSThemeSnapshot,
    viewModel: MessagesSectionedViewModel? = nil,
    messageViewImplementation: MessageViewImplementation? = nil
  ) {
    self.peerId = peerId
    self.chatId = chatId
    self.spaceId = spaceId
    self.isPreview = isPreview
    self.theme = theme
    let implementation = messageViewImplementation ?? MessageView2Feature.selectedImplementation(
      isExperimentAvailable: SettingsBuildAudience.showsDebugTools
    )
    let coordinator = Coordinator(
      peerId: peerId,
      chatId: chatId,
      spaceId: spaceId,
      collapsedMaxId: collapsedMaxId,
      isPreview: isPreview,
      sendAnimationCoordinator: sendAnimationCoordinator,
      theme: theme,
      messageViewImplementation: implementation,
      viewModel: viewModel
    )
    self.coordinator = coordinator
    let layout = MessagesCollectionView.createLayout { [weak coordinator] sectionIndex in
      coordinator?.sectionId(at: sectionIndex)
    }

    super.init(frame: .zero, collectionViewLayout: layout)

    setupCollectionView()
  }

  var highestPositiveMessageId: Int64? {
    coordinator.highestPositiveMessageId
  }

  func setCollapsedMaxId(_ collapsedMaxId: Int64?) {
    coordinator.setCollapsedMaxId(collapsedMaxId)
  }

  func applyTheme(_ theme: IOSThemeSnapshot) {
    guard self.theme != theme else { return }
    self.theme = theme
    coordinator.applyTheme(theme)
    syncVisibleBubbleGradients()
  }

  func collapseHistory(maxID: Int64?) async throws {
    let effectiveMaxID = try await Api.realtime.collapseHistory(peer: peerId.toInputPeer(), maxID: maxID)
    coordinator.setCollapsedMaxId(effectiveMaxID)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupCollectionView() {
    backgroundColor = .clear
    UIContextMenuInteraction.swizzle_delegate_getAccessoryViewsForConfigurationIfNeeded()
    delegate = coordinator
    autoresizingMask = [.flexibleHeight]
    alwaysBounceVertical = true

    if #available(iOS 26.0, *) {
      topEdgeEffect.isHidden = true
      bottomEdgeEffect.isHidden = true
    } else {}

    register(
      MessageCollectionViewCell.self,
      forCellWithReuseIdentifier: MessageCollectionViewCell.reuseIdentifier
    )

    register(
      DateSeparatorView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
      withReuseIdentifier: DateSeparatorView.reuseIdentifier
    )

    transform = CGAffineTransform(scaleX: 1, y: -1)
    showsVerticalScrollIndicator = true
    keyboardDismissMode = .interactive

    coordinator.setupDataSource(self)
    setupObservers()

    prefetchDataSource = self

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(orientationDidChange),
      name: UIDevice.orientationDidChangeNotification,
      object: nil
    )
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      isKeyboardVisible = false
      keyboardHeight = 0
      cancelSendAnimationScrollAnimations()
      coordinator.detachAvatarOverlay()
    } else {
      updateContentInsets()
      coordinator.attachAvatarOverlay(over: self, parent: findViewController())
      coordinator.syncAvatarOverlay(animate: false)
      syncVisibleBubbleGradients()
      DispatchQueue.main.async { [weak self] in
        self?.coordinator.resetVisibleReadCandidate()
        self?.coordinator.updateUnreadIfNeeded()
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    coordinator.syncAvatarOverlay(animate: false)
    reconcileScrollAffordance()
    syncVisibleBubbleGradients()
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden,
          alpha > 0.01,
          isUserInteractionEnabled,
          self.point(inside: point, with: event)
    else { return nil }

    // Resolve pinned-date presses before UIScrollView can consume them to stop scrolling.
    for case let separator as DateSeparatorView in visibleSupplementaryViews(
      ofKind: UICollectionView.elementKindSectionFooter
    ).reversed() {
      if let dateHit = separator.hitTest(convert(point, to: separator), with: event) {
        return dateHit
      }
    }
    return super.hitTest(point, with: event)
  }

  fileprivate func syncVisibleBubbleGradients() {
    guard let viewport = superview else { return }
    // Convert through the upright container so UIKit absorbs both the collection
    // and cell inversions. The bubble must never derive this phase from contentOffset.
    for case let cell as MessageCollectionViewCell in visibleCells {
      cell.updateContinuousBubbleGradient(in: viewport)
    }
  }

  fileprivate func syncBubbleGradient(for cell: MessageCollectionViewCell) {
    guard let viewport = superview else { return }
    cell.updateContinuousBubbleGradient(in: viewport)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)

    pendingScrollLoadTask?.cancel()
    cancelSendAnimationScrollAnimations()
    coordinator.dispose()

    if !isPreview {
      Task {
        await ImagePrefetcher.shared.clearCache()
      }
    }
  }

  func scrollToBottom() {
    guard !itemsEmpty else { return }

    let visibleHeight = bounds.height
    let targetOffsetY = -contentInset.top
    let currentOffsetY = contentOffset.y
    let distanceToScroll = abs(currentOffsetY - targetOffsetY)

    if distanceToScroll > visibleHeight * 3 {
      let intermediateOffsetY = targetOffsetY + (3 * visibleHeight)

      if currentOffsetY > intermediateOffsetY {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setContentOffset(CGPoint(x: 0, y: intermediateOffsetY), animated: false)
        layoutIfNeeded()
        CATransaction.commit()
      }

      animateScrollToBottom(duration: 0.14)
    } else {
      safeScrollToTop(animated: true)
    }
  }

  func scrollToMessageWhenAvailable(_ messageID: Int64) {
    messageFocusRevision &+= 1
    pendingScrollMessageID = messageID
    pendingScrollLoadTask?.cancel()
    pendingScrollLoadTask = nil

    guard !resolvePendingMessageScroll() else { return }

    let peer = peerId
    let limit = MessagesProgressiveViewModel.defaultInitialLimit()
    pendingScrollLoadTask = Task { @MainActor [weak self] in
      guard !Task.isCancelled else { return }

      do {
        let outcome = try await MessageHistoryRepairCoordinator.shared.loadAround(
          peer: peer,
          anchorID: messageID,
          limit: limit
        )
        guard let self, !Task.isCancelled, pendingScrollMessageID == messageID else { return }
        guard outcome != .empty, coordinator.loadLocalWindowAroundMessage(messageID) else {
          pendingScrollMessageID = nil
          pendingScrollLoadTask = nil
          ToastManager.shared.showToast(
            "Could not load that message",
            type: .error,
            systemImage: "exclamationmark.triangle.fill"
          )
          return
        }
        pendingScrollLoadTask = nil
        guard let displayedMessageID = coordinator.nearestDisplayedMessageID(to: messageID),
              resolvePendingMessageScroll(
                displayedMessageID: displayedMessageID,
                shouldHighlight: displayedMessageID == messageID
              )
        else {
          pendingScrollMessageID = nil
          ToastManager.shared.showToast(
            "Could not load that message",
            type: .error,
            systemImage: "exclamationmark.triangle.fill"
          )
          return
        }
      } catch is CancellationError {
        return
      } catch {
        guard let self, !Task.isCancelled, pendingScrollMessageID == messageID else { return }
        pendingScrollMessageID = nil
        pendingScrollLoadTask = nil
        Log.shared.error("Failed to load focused message", error: error)
        ToastManager.shared.showToast(
          "Could not load that message",
          type: .error,
          systemImage: "exclamationmark.triangle.fill"
        )
        return
      }
    }
  }

  func cancelPendingMessageFocus() {
    messageFocusRevision &+= 1
    pendingScrollLoadTask?.cancel()
    pendingScrollLoadTask = nil
    pendingScrollMessageID = nil
  }

  @discardableResult
  fileprivate func resolvePendingMessageScroll(
    displayedMessageID: Int64? = nil,
    shouldHighlight: Bool = true
  ) -> Bool {
    guard pendingScrollLoadTask == nil, let requestedMessageID = pendingScrollMessageID else { return false }
    let displayedMessageID = displayedMessageID ?? requestedMessageID
    guard let indexPath = findIndexPath(
      forMessageId: displayedMessageID,
      chatId: chatId,
      includeThreadAnchor: false
    ),
      isValidIndexPath(indexPath)
    else { return false }

    pendingScrollMessageID = nil
    pendingScrollLoadTask?.cancel()
    pendingScrollLoadTask = nil
    for cell in visibleCells {
      (cell as? MessageCollectionViewCell)?.clearHighlight()
    }
    scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
    guard shouldHighlight else { return true }

    let revision = messageFocusRevision
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      guard let self, messageFocusRevision == revision,
            let currentIndexPath = findIndexPath(
              forMessageId: displayedMessageID,
              chatId: chatId,
              includeThreadAnchor: false
            )
      else { return }
      for cell in visibleCells {
        (cell as? MessageCollectionViewCell)?.clearHighlight()
      }
      if isValidIndexPath(currentIndexPath),
         let cell = cellForItem(at: currentIndexPath) as? MessageCollectionViewCell
      {
        cell.highlightBubble()
      }
    }
    return true
  }

  private struct PendingSendAnimationComposeInset {
    let height: CGFloat
    let token: Int
  }

  private var composeHeight: CGFloat = ComposeView.minHeight
  private var pendingSendAnimationComposeInset: PendingSendAnimationComposeInset?
  private var pendingSendAnimationComposeInsetToken = 0
  private var pinnedHeaderHeight: CGFloat = 0

  private var visualBottomDistance: CGFloat {
    max(0, contentOffset.y + contentInset.top)
  }

  private var hasScrollableContent: Bool {
    contentSize.height + contentInset.top + contentInset.bottom
      > bounds.height + ScrollAffordanceMetrics.scrollabilityTolerance
  }

  fileprivate var isAtVisualBottomForUnread: Bool {
    visualBottomDistance <= ScrollAffordanceMetrics.unreadBottomDistance
  }

  private func beginScrollAffordanceUpdate() {
    scrollAffordanceUpdateDepth += 1
  }

  private func endScrollAffordanceUpdate() {
    scrollAffordanceUpdateDepth = max(0, scrollAffordanceUpdateDepth - 1)
    guard scrollAffordanceUpdateDepth == 0 else { return }
    reconcileScrollAffordance()
  }

  private func animateWhileSuppressingScrollAffordance(
    duration: TimeInterval,
    animations: @escaping () -> Void
  ) {
    beginScrollAffordanceUpdate()
    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState],
      animations: animations
    ) { [weak self] _ in
      self?.endScrollAffordanceUpdate()
    }
  }

  fileprivate func reconcileScrollAffordance() {
    guard !isPreview else { return }
    guard scrollAffordanceUpdateDepth == 0 else {
      return
    }

    let shouldShow: Bool = if !hasScrollableContent {
      false
    } else if scrollAffordanceState.isVisible {
      visualBottomDistance > ScrollAffordanceMetrics.hideDistance
    } else {
      visualBottomDistance > ScrollAffordanceMetrics.showDistance
    }

    guard shouldShow != scrollAffordanceState.isVisible else { return }
    scrollAffordanceState.isVisible = shouldShow
    onScrollAffordanceChanged?(scrollAffordanceState)
  }

  fileprivate func setScrollAffordanceHasUnread(_ hasUnread: Bool) {
    guard hasUnread != scrollAffordanceState.hasUnread else { return }
    scrollAffordanceState.hasUnread = hasUnread
    onScrollAffordanceChanged?(scrollAffordanceState)
  }

  var hasDeferredSendComposeInset: Bool {
    pendingSendAnimationComposeInset != nil
  }

  func updatePinnedHeaderHeight(_ height: CGFloat) {
    pinnedHeaderHeight = height
    updateContentInsets()
  }

  func updateComposeInset(
    composeHeight: CGFloat,
    animation: ComposeHeightChangeAnimation
  ) {
    pendingSendAnimationComposeInset = nil
    applyComposeInset(composeHeight: composeHeight, animation: animation)
  }

  func deferComposeInsetForPendingSendAnimation(composeHeight: CGFloat) {
    guard abs(self.composeHeight - composeHeight) > 0.5 else {
      pendingSendAnimationComposeInset = nil
      return
    }

    stopComposeInsetAnimationAtPresentation()
    pendingSendAnimationComposeInsetToken += 1
    let token = pendingSendAnimationComposeInsetToken
    pendingSendAnimationComposeInset = PendingSendAnimationComposeInset(
      height: composeHeight,
      token: token
    )

    SendMessageAnimationDiagnostics.event(
      "list compose-inset-deferred oldHeight=\(String(format: "%.1f", self.composeHeight)) newHeight=\(String(format: "%.1f", composeHeight)) insetTop=\(String(format: "%.1f", contentInset.top)) offsetY=\(String(format: "%.1f", contentOffset.y))"
    )

    DispatchQueue.main.asyncAfter(deadline: .now() + (SendMessageAnimationTiming.duration + 0.25)) { [weak self] in
      self?.flushDeferredComposeInsetForPendingSendAnimation(
        token: token,
        reason: "timeout"
      )
    }
  }

  @discardableResult
  func applyDeferredComposeInsetForPendingSendAnimationIfNeeded(reason: String) -> Bool {
    guard let pending = pendingSendAnimationComposeInset else { return false }

    pendingSendAnimationComposeInset = nil
    SendMessageAnimationDiagnostics.event(
      "list compose-inset-apply-deferred reason=\(reason) oldHeight=\(String(format: "%.1f", composeHeight)) newHeight=\(String(format: "%.1f", pending.height)) insetTop=\(String(format: "%.1f", contentInset.top)) offsetY=\(String(format: "%.1f", contentOffset.y))"
    )
    applyComposeInset(
      composeHeight: pending.height,
      animation: .immediate,
      scrollToBottomIfNeeded: false
    )
    return true
  }

  private func flushDeferredComposeInsetForPendingSendAnimation(token: Int, reason: String) {
    guard
      let pending = pendingSendAnimationComposeInset,
      pending.token == token
    else {
      return
    }

    pendingSendAnimationComposeInset = nil
    SendMessageAnimationDiagnostics.event(
      "list compose-inset-flush-deferred reason=\(reason) oldHeight=\(String(format: "%.1f", composeHeight)) newHeight=\(String(format: "%.1f", pending.height)) insetTop=\(String(format: "%.1f", contentInset.top)) offsetY=\(String(format: "%.1f", contentOffset.y))"
    )
    applyComposeInset(
      composeHeight: pending.height,
      animation: .animated(
        duration: SendMessageAnimationTiming.duration,
        timingParameters: SendMessageAnimationTiming.verticalTimingParameters
      )
    )
  }

  private func applyComposeInset(
    composeHeight: CGFloat,
    animation: ComposeHeightChangeAnimation,
    scrollToBottomIfNeeded: Bool = true
  ) {
    let wasAtBottom = !itemsEmpty && shouldScrollToBottom
    beginScrollAffordanceUpdate()
    defer { endScrollAffordanceUpdate() }

    guard animation.isAnimated else {
      stopComposeInsetAnimationAtPresentation()
      self.composeHeight = composeHeight
      UIView.performWithoutAnimation {
        updateContentInsets()
        if scrollToBottomIfNeeded, wasAtBottom {
          safeScrollToTop(animated: false)
        }
        layoutIfNeeded()
      }
      return
    }

    stopComposeInsetAnimationAtPresentation()
    let previousTopInset = contentInset.top
    let previousOffset = contentOffset
    self.composeHeight = composeHeight

    UIView.performWithoutAnimation {
      updateContentInsets()
      if wasAtBottom {
        setContentOffset(previousOffset, animated: false)
      }
    }

    guard wasAtBottom else { return }

    let insetDelta = contentInset.top - previousTopInset
    let targetOffset = CGPoint(
      x: previousOffset.x,
      y: previousOffset.y - insetDelta
    )

    // Keep visibility frozen for the full property-animation lifetime. The outer
    // suppression below covers model/inset updates; this nested scope is released
    // by both normal completion and presentation-preserving cancellation.
    beginScrollAffordanceUpdate()
    sendAnimationScrollState.startComposeInsetAnimation(
      to: targetOffset,
      duration: animation.duration,
      timingParameters: animation.timingParameters,
      in: self
    ) { [weak self] in
      self?.endScrollAffordanceUpdate()
    }
  }

  @discardableResult
  private func stopComposeInsetAnimationAtPresentation() -> Bool {
    sendAnimationScrollState.stopComposeInsetAnimationAtPresentation(in: self)
  }

  private func cancelSendAnimationScrollAnimations() {
    sendAnimationScrollState.cancel(in: self)
  }

  private func clampedSendAnimationContentOffset(_ offset: CGPoint) -> CGPoint {
    sendAnimationScrollState.clampedContentOffset(offset, in: self)
  }

  static let messagesBottomPadding = 12.0
  func updateContentInsets() {
    guard !isContextMenuOpen else {
      needsContentInsetUpdateAfterContextMenu = true
      return
    }
    guard let window else {
      return
    }
    needsContentInsetUpdateAfterContextMenu = false

    // let topContentPadding: CGFloat = 10
    let topContentPadding: CGFloat = -10
    let navBarHeight = (findViewController()?.navigationController?.navigationBar.frame.height ?? 0)
    if navBarHeight > 0 {
      lastKnownNavBarHeight = navBarHeight
    }
    let effectiveNavBarHeight = navBarHeight > 0 ? navBarHeight : lastKnownNavBarHeight

    let isLandscape = UIDevice.current.orientation.isLandscape

    // let topSafeArea = isLandscape ? window.safeAreaInsets.left : window.safeAreaInsets.top
    let topSafeArea = isLandscape ? window.safeAreaInsets.top : window.safeAreaInsets.top
//    let bottomSafeArea = isLandscape ? window.safeAreaInsets.right : window.safeAreaInsets.bottom
    let bottomSafeArea = isLandscape ? window.safeAreaInsets.bottom : window.safeAreaInsets.bottom
    let navBarInset = topSafeArea + effectiveNavBarHeight
    let totalTopInset = navBarInset + pinnedHeaderHeight

    NotificationCenter.default.post(
      name: Notification.Name("NavigationBarHeight"),
      object: nil,
      userInfo: [
        "navBarHeight": navBarInset,
      ]
    )

    var bottomInset: CGFloat = 0.0

    if !isPreview {
      bottomInset += composeHeight + (ComposeView.textViewVerticalMargin * 2)
    }
    bottomInset += Self.messagesBottomPadding
    if isKeyboardVisible {
      bottomInset += keyboardHeight
    } else {
      bottomInset += bottomSafeArea
    }

    contentInsetAdjustmentBehavior = .never
    automaticallyAdjustsScrollIndicatorInsets = false

    scrollIndicatorInsets = UIEdgeInsets(top: bottomInset, left: 0, bottom: totalTopInset, right: 0)
    contentInset = UIEdgeInsets(top: bottomInset, left: 0, bottom: totalTopInset + topContentPadding, right: 0)
    layoutIfNeeded()
    coordinator.syncAvatarOverlay(animate: false)
    reconcileScrollAffordance()
  }

  private func updateContentInsetsAfterContextMenuIfNeeded(animated: Bool) {
    guard needsContentInsetUpdateAfterContextMenu else { return }

    let wasAtBottom = shouldScrollToBottom
    guard animated, wasAtBottom, !itemsEmpty else {
      beginScrollAffordanceUpdate()
      defer { endScrollAffordanceUpdate() }
      updateContentInsets()
      if wasAtBottom, !itemsEmpty {
        safeScrollToTop(animated: false)
      }
      return
    }

    beginScrollAffordanceUpdate()
    updateContentInsets()
    UIView.animate(
      withDuration: 0.2,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      self.safeScrollToTop(animated: false)
    } completion: { [weak self] _ in
      self?.endScrollAffordanceUpdate()
    }
  }

  var shouldScrollToBottom: Bool {
    visualBottomDistance <= ScrollAffordanceMetrics.showDistance
  }

  var itemsEmpty: Bool {
    coordinator.items.isEmpty
  }

  private func findIndexPath(
    forMessageId messageId: Int64,
    chatId: Int64? = nil,
    includeThreadAnchor: Bool = true
  ) -> IndexPath? {
    for (sectionIndex, section) in coordinator.listSections.enumerated() {
      for (itemIndex, item) in section.items.enumerated() {
        if item.isThreadAnchor, !includeThreadAnchor { continue }
        guard let message = coordinator.message(for: item) else { continue }
        guard message.message.messageId == messageId else { continue }
        if let chatId, message.message.chatId != chatId { continue }

        let indexPath = IndexPath(item: itemIndex, section: sectionIndex)
        // Validate the index path before returning
        if isValidIndexPath(indexPath) {
          return indexPath
        }
      }
    }
    return nil
  }

  private func findIndexPath(forStableMessageId stableId: Int64) -> IndexPath? {
    for (sectionIndex, section) in coordinator.listSections.enumerated() {
      for (itemIndex, item) in section.items.enumerated() {
        guard item.messageStableId == stableId else { continue }

        let indexPath = IndexPath(item: itemIndex, section: sectionIndex)
        if isValidIndexPath(indexPath) {
          return indexPath
        }
      }
    }
    return nil
  }

  private func isValidIndexPath(_ indexPath: IndexPath) -> Bool {
    // Check both view model and collection view data source to avoid race conditions
    guard indexPath.section >= 0,
          indexPath.section < coordinator.numberOfSections(),
          indexPath.item >= 0,
          indexPath.item < coordinator.numberOfItems(in: indexPath.section),
          indexPath.section < numberOfSections,
          indexPath.item < numberOfItems(inSection: indexPath.section)
    else {
      return false
    }
    return true
  }

  func sourceViewForMessageStableId(_ stableId: Int64) -> UIView? {
    guard let indexPath = findIndexPath(forStableMessageId: stableId),
          let cell = cellForItem(at: indexPath) as? MessageCollectionViewCell
    else {
      return nil
    }

    return cell.messageView?.newPhotoView.imageView
  }

  private func safeScrollToTop(animated: Bool = true) {
    // Check both view model and data source to avoid race conditions
    guard coordinator.numberOfSections() > 0,
          coordinator.numberOfItems(in: 0) > 0,
          numberOfSections > 0,
          numberOfItems(inSection: 0) > 0
    else {
      return
    }

    let indexPath = IndexPath(item: 0, section: 0)
    scrollToItem(at: indexPath, at: .top, animated: animated)
  }

  private func makeSendAnimationScrollPlanToBottom(
    currentOffsetY: CGFloat? = nil
  ) -> SendMessageAnimationScrollPlan? {
    guard coordinator.numberOfSections() > 0,
          coordinator.numberOfItems(in: 0) > 0,
          numberOfSections > 0,
          numberOfItems(inSection: 0) > 0
    else {
      return nil
    }

    layoutIfNeeded()

    let indexPath = IndexPath(item: 0, section: 0)
    guard let attributes = layoutAttributesForItem(at: indexPath) else { return nil }

    let unclampedTargetOffset = CGPoint(
      x: contentOffset.x,
      y: attributes.frame.minY - contentInset.top
    )
    let targetOffset = sendAnimationScrollState.clampedContentOffset(
      unclampedTargetOffset,
      in: self
    )
    if abs(unclampedTargetOffset.y - targetOffset.y) > 0.5 {
      SendMessageAnimationDiagnostics.debug(
        "list scroll-plan-clamped rawY=\(String(format: "%.1f", unclampedTargetOffset.y)) clampedY=\(String(format: "%.1f", targetOffset.y)) minY=\(String(format: "%.1f", -contentInset.top)) maxY=\(String(format: "%.1f", max(-contentInset.top, contentSize.height - bounds.height + contentInset.bottom)))"
      )
    }
    let modelContentOffsetYDeltaToTarget = targetOffset.y - contentOffset.y
    let effectiveCurrentOffsetY = currentOffsetY ?? contentOffset.y
    let presentationContentOffsetYDeltaToTarget = targetOffset.y - effectiveCurrentOffsetY
    guard abs(modelContentOffsetYDeltaToTarget) > 0.5 ||
      abs(presentationContentOffsetYDeltaToTarget) > 0.5
    else {
      return nil
    }

    let presentationDelta: CGFloat? = if currentOffsetY == nil {
      nil
    } else {
      presentationContentOffsetYDeltaToTarget
    }

    return SendMessageAnimationScrollPlan(
      targetOffset: targetOffset,
      modelContentOffsetYDeltaToTarget: modelContentOffsetYDeltaToTarget,
      presentationContentOffsetYDeltaToTarget: presentationDelta
    )
  }

  private var isSendAnimationScrollInFlight: Bool {
    sendAnimationScrollState.isScrollInFlight
  }

  private func activeSendAnimationScrollPlanToTarget() -> SendMessageAnimationScrollPlan? {
    sendAnimationScrollState.activeScrollPlanToTarget(in: self)
  }

  private func animateSendAnimationScrollToBottom(
    targetOffset: CGPoint,
    duration: TimeInterval
  ) {
    beginScrollAffordanceUpdate()
    sendAnimationScrollState.animateScroll(
      to: targetOffset,
      duration: duration,
      in: self
    ) { [weak self] in
      self?.endScrollAffordanceUpdate()
    }
  }

  @objc func orientationDidChange(_ notification: Notification) {
    coordinator.clearSizeCache()
//    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    DispatchQueue.main.async {
      guard self.window != nil else { return }
      self.layoutIfNeeded()
      self.coordinator.reconfigureVisibleItemsForCurrentWidth()
      guard !self.isKeyboardVisible else { return }

      let wasAtBottom = self.shouldScrollToBottom

      self.animateWhileSuppressingScrollAffordance(duration: 0.3) {
        self.updateContentInsets()
        if wasAtBottom, !self.itemsEmpty {
          self.safeScrollToTop(animated: false)
        }
      }
    }
  }

  func findViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let nextResponder = responder?.next {
      if let viewController = nextResponder as? UIViewController {
        return viewController
      }
      responder = nextResponder
    }
    return nil
  }

  private func setupObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(replyStateChanged),
      name: .init("ChatStateSetReplyCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(replyStateChanged),
      name: .init("ChatStateClearReplyCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(replyStateChanged),
      name: .init("ChatStateSetEditingCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(replyStateChanged),
      name: .init("ChatStateClearEditingCalled"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillShow),
      name: UIResponder.keyboardWillShowNotification,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillHide),
      name: UIResponder.keyboardWillHideNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleScrollToRepliedMessage(_:)),
      name: Notification.Name("ScrollToRepliedMessage"),
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  @objc private func applicationDidBecomeActive() {
    DispatchQueue.main.async { [weak self] in
      self?.coordinator.resetVisibleReadCandidate()
      self?.coordinator.updateUnreadIfNeeded()
    }
  }

  var isKeyboardVisible: Bool = false
  var keyboardHeight: CGFloat = 0

  @objc private func keyboardWillShow(_ notification: Notification) {
    guard window != nil else { return }
    let wasAtBottom = shouldScrollToBottom

    isKeyboardVisible = true
    guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
          let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
    else {
      return
    }
    let keyboardFrameHeight = keyboardFrame.height
    keyboardHeight = keyboardFrameHeight

    beginScrollAffordanceUpdate()
    updateContentInsets()
    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      if wasAtBottom, !self.itemsEmpty {
        self.safeScrollToTop(animated: false)
      }
    } completion: { [weak self] _ in
      self?.endScrollAffordanceUpdate()
    }
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    guard window != nil else { return }
    let wasAtBottom = shouldScrollToBottom

    isKeyboardVisible = false
    keyboardHeight = 0
    guard let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else {
      return
    }

    beginScrollAffordanceUpdate()
    updateContentInsets()
    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      if wasAtBottom, !self.itemsEmpty {
        self.safeScrollToTop(animated: false)
      }
    } completion: { [weak self] _ in
      self?.endScrollAffordanceUpdate()
    }
  }

  @objc private func replyStateChanged(_ notification: Notification) {
    DispatchQueue.main.async {
      let wasAtBottom = self.shouldScrollToBottom
      self.animateWhileSuppressingScrollAffordance(duration: 0.2) {
        self.updateContentInsets()
        if wasAtBottom, !self.itemsEmpty {
          self.safeScrollToTop(animated: false)
        }
      }
    }
  }

  private func animateScrollToBottom(duration: TimeInterval) {
    // Check both view model and data source to avoid race conditions
    guard coordinator.numberOfSections() > 0,
          coordinator.numberOfItems(in: 0) > 0,
          numberOfSections > 0,
          numberOfItems(inSection: 0) > 0 else { return }

    let indexPath = IndexPath(item: 0, section: 0)
    if let attributes = layoutAttributesForItem(at: indexPath) {
      let targetOffset = CGPoint(x: 0, y: attributes.frame.minY - contentInset.top)
      UIView.animate(
        withDuration: duration,
        delay: 0,
        options: [.curveEaseOut, .allowUserInteraction],
        animations: {
          self.contentOffset = targetOffset
        }
      )
    }
  }

  private static func createLayout(
    sectionIdProvider: @escaping (Int) -> MessageListSectionID?
  ) -> UICollectionViewLayout {
    AnimatedCompositionalLayout.createSectionedLayout(sectionIdProvider: sectionIdProvider)
  }

  // TODO: Handle far reply scroll
  // TODO: Add ensure message
  @objc private func handleScrollToRepliedMessage(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let repliedToMessageId = userInfo["repliedToMessageId"] as? Int64,
          let chatId = userInfo["chatId"] as? Int64,
          chatId == self.chatId else { return }
    scrollToMessageWhenAvailable(repliedToMessageId)
  }
}

// MARK: - UICollectionViewDataSourcePrefetching

extension MessagesCollectionView: UICollectionViewDataSourcePrefetching {
  func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    // Get messages on main actor, then move heavy work to background
    let messagesToPrefetch: [FullMessage] = indexPaths.compactMap { indexPath in
      coordinator.message(at: indexPath)
    }

    if !messagesToPrefetch.isEmpty {
      // Move only the image prefetching to background thread
      Task.detached(priority: .utility) {
        await ImagePrefetcher.shared.prefetchImages(for: messagesToPrefetch)
      }
    }
  }

  func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
    // Get messages on main actor, then move heavy work to background
    let messagesToCancel: [FullMessage] = indexPaths.compactMap { indexPath in
      coordinator.message(at: indexPath)
    }

    if !messagesToCancel.isEmpty {
      // Move only the cancel prefetching to background thread
      Task.detached(priority: .utility) {
        await ImagePrefetcher.shared.cancelPrefetching(for: messagesToCancel)
      }
    }
  }

  @objc func _contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    styleForMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> Any? {
    guard let window else { return nil }

    let navBarHeight = (findViewController()?.navigationController?.navigationBar.frame.height ?? 0)
    if navBarHeight > 0 {
      lastKnownNavBarHeight = navBarHeight
    }
    let effectiveNavBarHeight = navBarHeight > 0 ? navBarHeight : lastKnownNavBarHeight
    let topSafeArea = window.safeAreaInsets.top
    let totalTopInset = topSafeArea + effectiveNavBarHeight

    let styleClass = NSClassFromString("_UIContextMenuStyle") as? NSObject.Type
    guard let style = styleClass?.perform(NSSelectorFromString("defaultStyle"))?.takeUnretainedValue() as? NSObject
    else {
      return nil
    }

    style.setValue(
      UIEdgeInsets(top: totalTopInset, left: 30, bottom: 0, right: 30),
      forKey: "preferredEdgeInsets"
    )

    return style
  }
}

// MARK: - Coordinator

private extension MessagesCollectionView {
  class Coordinator: NSObject, UICollectionViewDelegateFlowLayout {
    private var currentCollectionView: UICollectionView?
    let viewModel: MessagesSectionedViewModel
    private let translationViewModel: TranslationViewModel
    private var hasAnalyzedInitialMessages = false
    private let peerId: Peer
    private let chatId: Int64
    private let spaceId: Int64?
    private let isPreview: Bool
    private var theme: IOSThemeSnapshot
    private let messageViewImplementation: MessageViewImplementation
    private weak var collectionContextMenu: UIContextMenuInteraction?
    private var cancellables = Set<AnyCancellable>()
    private var updateWorkItem: DispatchWorkItem?
    private var olderLoadTask: Task<Void, Never>?
    private var olderHistoryPagination = OlderHistoryPagination()
    private var olderHistoryCheckScheduled = false
    private var newerLoadTask: Task<Void, Never>?
    private var lastNewerAttempt: (messageID: Int64, date: Date)?
    private var threadAnchorFetchTask: Task<Void, Never>?
    private var didExhaustThreadAnchorFetch = false
    private var isPresentingImageViewer = false
    private let groupCalendar = Calendar.current
    private let avatarOverlayController = MessageAvatarOverlayViewController()
    private var groupInfoByItem: [MessageListItem: MessageGroupInfo] = [:]
    private var pendingAppearingItems: Set<MessageListItem> = []
    private var sendAnimationListTransaction = SendMessageAnimationListTransaction()
    private weak var sendAnimationCoordinator: SendMessageAnimationCoordinator?
    private var mediaWarmupTask: Task<Void, Never>?
    private var mediaWarmups: [InlineTinyThumbnailWarmup] = []
    private var v2GeometryAnimator: UIViewPropertyAnimator?
    private var v2GeometryTransitions: [V2GeometryTransition] = []
    private var pendingV2GeometryTransitions: [V2GeometryTransition] = []
    private var pendingV2GeometryViewport: V2GeometryViewport?
    private var v2GeometryFlushScheduled = false
    private var pendingSnapshotApplies = 0

    @MainActor private struct V2GeometryViewport {
      let bounds: CGRect
      let adjustedContentInset: UIEdgeInsets
      let window: UIWindow
      let geometry: MessageListGeometrySnapshotV2
      let anchor: SendAnimationContentAnchor?
    }

    @MainActor private struct V2GeometryTransition {
      weak var cell: MessageCollectionViewCell?
      weak var view: UIMessageView2?
      let layout: MessageBubbleLayoutV2
      let generation: UInt
      let messageID: Int64

      var isCurrent: Bool {
        guard let cell, let view else { return false }
        return cell.messageView === view
          && cell.message?.id == messageID
          && view.geometryTransitionGeneration == generation
      }

      func apply() {
        guard isCurrent else { return }
        view?.applyGeometryTransition(to: layout, generation: generation)
      }

      func finish() {
        guard isCurrent else { return }
        view?.finishGeometryTransition(generation: generation)
      }
    }
    private var deferredContextMenuUpdatedMessageIDs = Set<Int64>()
    private var deferredContextMenuUpdateAnimated = false
    private var lastVisibleReadCandidateID: Int64?
    private var lastVisibleReadCoverage: MessageHistoryCoverageProjection?

    private struct MessageGroupInfo {
      let ownerItem: MessageListItem
      let isFirst: Bool
      let isLast: Bool
    }

    private struct SendAnimationContentAnchor {
      let item: MessageListItem
      let frameInWindow: CGRect
      let contentOffset: CGPoint
    }

    private struct AvatarOverlayDraft {
      let stableId: Int64
      let userInfo: UserInfo
      let avatarX: CGFloat
      let avatarSize: CGFloat
      let viewportFrame: CGRect
      let onTap: () -> Void
      var frame: CGRect?
      var limitFrame: CGRect
    }

    // MARK: - Date Separator Visibility Handling

    fileprivate var dateSeparatorHideWorkItem: DispatchWorkItem?
    /// Delay before the pinned date badge is hidden after scrolling stops.
    /// Adjust this value to tweak the UX (similar to WhatsApp/Telegram/Signal).
    fileprivate let dateSeparatorHideDelay: TimeInterval = 0.5

    func collectionView(
      _ collectionView: UICollectionView,
      willDisplay cell: UICollectionViewCell,
      forItemAt indexPath: IndexPath
    ) {
      defer {
        if let messagesCollectionView = collectionView as? MessagesCollectionView,
           let cell = cell as? MessageCollectionViewCell
        {
          messagesCollectionView.syncBubbleGradient(for: cell)
        }
      }
      guard let item = item(at: indexPath) else {
        cell.alpha = 1
        if let cell = cell as? MessageCollectionViewCell {
          cell.revealSendAnimationTarget()
        }
        return
      }

      guard pendingAppearingItems.remove(item) != nil else {
        cell.alpha = 1
        if let cell = cell as? MessageCollectionViewCell {
          if cell.isPreparedForSendAnimationTarget,
             let identity = sendAnimationIdentity(for: item)
          {
            if sendAnimationCoordinator?.isAnimating(identity: identity) == true {
              SendMessageAnimationDiagnostics.debug(
                "willDisplay keep-hidden item=\(item) preparedTarget=true state=animating"
              )
              return
            }

            SendMessageAnimationDiagnostics.debug(
              "willDisplay keep-hidden item=\(item) preparedTarget=true state=pending-final-layout"
            )
            return
          }
          cell.revealSendAnimationTarget()
        }
        return
      }

      if let cell = cell as? MessageCollectionViewCell {
        if cell.isPreparedForSendAnimationTarget,
           let identity = sendAnimationIdentity(for: item)
        {
          SendMessageAnimationDiagnostics.debug(
            "willDisplay keep-hidden item=\(item) preparedTarget=true state=\(sendAnimationCoordinator?.isAnimating(identity: identity) == true ? "animating" : "pending-final-layout")"
          )
          return
        }
        cell.animateInsertion()
      } else {
        cell.alpha = 0
        UIView.animate(
          withDuration: 0.16,
          delay: 0,
          options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
          cell.alpha = 1
        }
      }
    }

    private func beginSendAnimationTargetIfPossible(
      for item: MessageListItem,
      at indexPath: IndexPath,
      cell: MessageCollectionViewCell,
      finalizedScrollPlan: SendMessageAnimationScrollPlan? = nil,
      fallbackAnimatesInsertion: Bool
    ) -> Bool {
      let wasSendAnimationTarget = cell.isPreparedForSendAnimationTarget
      guard wasSendAnimationTarget else {
        return false
      }

      if let targetStart = makeSendAnimationTargetStart(
        for: item,
        at: indexPath,
        cell: cell,
        finalizedScrollPlan: finalizedScrollPlan
      ) {
        let target = targetStart.target
        let didBegin = SendMessageAnimationActions.performWithAnimationsEnabled(
          reason: "begin-preview-and-scroll"
        ) {
          let didBegin = sendAnimationCoordinator?.beginIfPossible(
            target: target,
            revealTarget: { [weak self, weak cell] latestTarget in
              guard let cell,
                    Self.cell(cell, matchesSendAnimationTarget: latestTarget)
              else {
                return
              }
              cell.revealSendAnimationTarget()
              self?.logFinalSendAnimationTargetFrame(
                target: latestTarget,
                expectedBubbleFrameInWindow: latestTarget.bubbleFrameInWindow,
                expectedTextFrameInWindow: latestTarget.textFrameInWindow,
                cell: cell
              )
            }
          ) == true

          if didBegin,
             let scrollTargetOffset = targetStart.scrollTargetOffset,
             let scrollDuration = targetStart.scrollDuration,
             let collectionView = currentCollectionView as? MessagesCollectionView
          {
            collectionView.animateSendAnimationScrollToBottom(
              targetOffset: scrollTargetOffset,
              duration: scrollDuration
            )
          }

          return didBegin
        }

        if didBegin {
          removePendingSendAnimationScrollTarget(item: item, identity: target.identity)
          return true
        }

        sendAnimationCoordinator?.cancel(identity: target.identity)
        removePendingSendAnimationScrollTarget(item: item, identity: target.identity)
        SendMessageAnimationDiagnostics.event(
          "willDisplay fallback-cancel-preview item=\(item) preparedTarget=\(wasSendAnimationTarget)"
        )
      } else if wasSendAnimationTarget {
        let identity = sendAnimationIdentity(for: item)
        removePendingSendAnimationScrollTarget(item: item, identity: identity)
        if let identity {
          sendAnimationCoordinator?.cancel(identity: identity)
        }
        SendMessageAnimationDiagnostics.event(
          "willDisplay fallback-cancel-unavailable-target item=\(item) random=\(identity.map { String($0.randomId) } ?? "nil")"
        )
      }

      if wasSendAnimationTarget {
        SendMessageAnimationDiagnostics.event(
          "willDisplay fallback-default item=\(item) preparedTarget=true insertion=\(fallbackAnimatesInsertion)"
        )
        cell.revealSendAnimationTarget()
        if fallbackAnimatesInsertion {
          cell.prepareInsertionAnimation()
        } else {
          return true
        }
      }
      return false
    }

    func collectionView(
      _ collectionView: UICollectionView,
      willDisplayContextMenu configuration: UIContextMenuConfiguration,
      animator: UIContextMenuInteractionAnimating?
    ) {
      (collectionView as? MessagesCollectionView)?.isContextMenuOpen = true

      if collectionContextMenu == nil,
         let int = collectionView.interactions
         .first(where: { $0 is UIContextMenuInteraction }) as? UIContextMenuInteraction
      {
        collectionContextMenu = int
      }
    }

    func collectionView(
      _ collectionView: UICollectionView,
      willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
      animator: UIContextMenuInteractionAnimating?
    ) {
      if let identifierView = configuration.identifier as? ContextMenuIdentifierUIView {
        identifierView.removeFromSuperview()
      }

      let updateInsets: (_ animated: Bool) -> Void = { [weak collectionView] animated in
        guard let collectionView = collectionView as? MessagesCollectionView else { return }
        collectionView.updateContentInsetsAfterContextMenuIfNeeded(animated: animated)
      }
      if let animator {
        animator.addAnimations {
          updateInsets(true)
        }
        animator.addCompletion { [weak self, weak collectionView] in
          (collectionView as? MessagesCollectionView)?.isContextMenuOpen = false
          self?.flushDeferredContextMenuMessageUpdates()
        }
      } else {
        DispatchQueue.main.async { [weak self, weak collectionView] in
          updateInsets(true)
          (collectionView as? MessagesCollectionView)?.isContextMenuOpen = false
          self?.flushDeferredContextMenuMessageUpdates()
        }
      }
    }

    private func dismissContextMenuIfNeeded() {
      collectionContextMenu?.dismissMenu()
    }

    private var dataSource: UICollectionViewDiffableDataSource<MessageListSectionID, MessageListItem>!
    private(set) var listSections: [MessageListSection] = []

    var messages: [FullMessage] {
      viewModel.sections.flatMap(\.messages)
    }

    var highestPositiveMessageId: Int64? {
      viewModel.highestPositiveMessageId
    }

    var items: [MessageListItem] {
      listSections.flatMap(\.items)
    }

    private func rebuildListSections() {
      listSections = makeListSections()
      rebuildMessageGroups()
    }

    private func rebuildMessageGroups() {
      var info: [MessageListItem: MessageGroupInfo] = [:]

      for section in listSections {
        let items = section.items
        var index = items.startIndex

        while index < items.endIndex {
          guard case .message = items[index], message(for: items[index]) != nil else {
            index += 1
            continue
          }

          var end = index
          while end + 1 < items.endIndex,
                let earlier = message(for: items[end + 1]),
                let later = message(for: items[end]),
                canGroup(earlier, later)
          {
            end += 1
          }

          let ownerItem = items[index]
          for itemIndex in index ... end {
            info[items[itemIndex]] = MessageGroupInfo(
              ownerItem: ownerItem,
              isFirst: itemIndex == end,
              isLast: itemIndex == index
            )
          }

          index = end + 1
        }
      }

      groupInfoByItem = info
    }

    private func makeListSections() -> [MessageListSection] {
      var sections = viewModel.sections.map { section in
        MessageListSection(
          id: .messages(dayStart: section.date),
          dayString: section.dayString,
          items: section.messages.map { .message(id: $0.id) }
        )
      }

      if viewModel.collapsedMaxId != nil {
        sections.append(MessageListSection(
          id: .collapsedHistory,
          dayString: nil,
          items: [.collapsedHistory]
        ))
      }

      if let anchor = viewModel.threadAnchor {
        // The collection view is inverted, so the last section is the visual top.
        sections.append(MessageListSection(
          id: .threadContext,
          dayString: nil,
          items: [.threadAnchor(id: anchor.id)]
        ))
      }

      return sections
    }

    func sectionId(at index: Int) -> MessageListSectionID? {
      listSection(at: index)?.id
    }

    private func listSection(at index: Int) -> MessageListSection? {
      let sections = listSections
      guard index >= 0, index < sections.count else { return nil }
      return sections[index]
    }

    private func scrollToFirstMessage(in sectionID: MessageListSectionID) {
      let snapshot = dataSource.snapshot()
      guard let collectionView = currentCollectionView,
            snapshot.sectionIdentifiers.contains(sectionID),
            let firstChronologicalItem = snapshot.itemIdentifiers(inSection: sectionID).last,
            let indexPath = dataSource.indexPath(for: firstChronologicalItem),
            indexPath.section < collectionView.numberOfSections,
            indexPath.item < collectionView.numberOfItems(inSection: indexPath.section)
      else {
        #if DEBUG || DEBUG_BUILD
        Log.shared.debug("date-navigation event=target-unavailable")
        #endif
        return
      }

      // Sections are newest-first and the collection is inverted. The last item
      // is the day's first message; physical `.bottom` aligns it with the visual top.
      dateSeparatorHideWorkItem?.cancel()
      setDateSeparators(hidden: false, animated: false)
      let animated = !UIAccessibility.isReduceMotionEnabled
      #if DEBUG || DEBUG_BUILD
      Log.shared.debug(
        "date-navigation event=scroll-request animated=\(animated) tracking=\(collectionView.isTracking) dragging=\(collectionView.isDragging) keyboard=\((collectionView as? MessagesCollectionView)?.isKeyboardVisible ?? false) offsetY=\(collectionView.contentOffset.y)"
      )
      #endif
      collectionView.scrollToItem(
        at: indexPath,
        at: .bottom,
        animated: animated
      )
      if !animated {
        scheduleHideDateSeparators()
      }
    }

    private func item(at indexPath: IndexPath) -> MessageListItem? {
      guard let section = listSection(at: indexPath.section),
            indexPath.item >= 0,
            indexPath.item < section.items.count
      else {
        return nil
      }
      return section.items[indexPath.item]
    }

    func message(at indexPath: IndexPath) -> FullMessage? {
      guard let item = item(at: indexPath) else { return nil }
      return message(for: item)
    }

    func message(for item: MessageListItem) -> FullMessage? {
      switch item {
        case let .message(id):
          viewModel.messagesByID[id]
        case let .threadAnchor(id):
          if viewModel.threadAnchor?.id == id {
            viewModel.threadAnchor
          } else {
            nil
          }
        case .unreadSeparator, .collapsedHistory:
          nil
      }
    }

    private func model(for item: MessageListItem) -> MessageListItemModel? {
      switch item {
        case .message:
          guard let message = message(for: item) else { return nil }
          return MessageListItemModel(content: .message(message, displayMode: .normal))
        case .threadAnchor:
          guard let message = message(for: item) else { return nil }
          return MessageListItemModel(content: .message(message, displayMode: .threadAnchor))
        case .unreadSeparator:
          return MessageListItemModel(content: .unreadSeparator(title: "Unread messages"))
        case .collapsedHistory:
          return MessageListItemModel(content: .collapsedHistory(title: "Cleared"))
      }
    }

    func setCollapsedMaxId(_ collapsedMaxId: Int64?) {
      viewModel.setCollapsedMaxId(collapsedMaxId)
    }

    func loadLocalWindowAroundMessage(_ messageID: Int64) -> Bool {
      olderLoadTask?.cancel()
      olderLoadTask = nil
      olderHistoryPagination.reset()
      newerLoadTask?.cancel()
      return viewModel.loadLocalWindowAroundMessage(messageId: messageID)
    }

    func nearestDisplayedMessageID(to coordinate: Int64) -> Int64? {
      let messageIDs = messages.lazy.map(\.message.messageId).filter { $0 > 0 }
      if messageIDs.contains(coordinate) { return coordinate }
      return messageIDs.filter { $0 > coordinate }.min()
        ?? messageIDs.filter { $0 < coordinate }.max()
    }

    private static func cell(
      _ cell: MessageCollectionViewCell,
      matchesSendAnimationTarget target: SendMessageAnimationTarget
    ) -> Bool {
      guard let message = cell.message else { return false }
      if message.id == target.messageStableId {
        return true
      }
      if message.message.messageId == target.identity.temporaryMessageId {
        return true
      }
      if let randomId = message.message.randomId,
         randomId == target.identity.randomId
      {
        return true
      }
      return false
    }

    private func sendAnimationIdentity(for item: MessageListItem) -> SendMessageAnimationIdentity? {
      guard let message = message(for: item) else { return nil }
      return sendAnimationCoordinator?.pendingIdentity(for: message)
    }

    private func isPendingSendAnimationScrollTarget(
      item: MessageListItem,
      identity: SendMessageAnimationIdentity
    ) -> Bool {
      sendAnimationListTransaction.contains(item: item, identity: identity)
    }

    private func removePendingSendAnimationScrollTarget(
      item: MessageListItem,
      identity: SendMessageAnimationIdentity?
    ) {
      sendAnimationListTransaction.remove(item: item, identity: identity)
    }

    private func beginPendingSendAnimationTargetsAfterApply(
      _ items: Set<MessageListItem>,
      identities: Set<SendMessageAnimationIdentity>,
      collectionView: MessagesCollectionView,
      contentAnchor: SendAnimationContentAnchor?
    ) {
      let beginTargets = { [weak self, weak collectionView] in
        guard let self, let collectionView else { return }

        let remaining = sendAnimationListTransaction.remainder(
          for: items,
          identities: identities
        )
        guard !remaining.isEmpty else {
          SendMessageAnimationDiagnostics.debug(
            "post-apply target-start skipped remaining=empty items=\(items.count) identities=\(identities.count)"
          )
          return
        }

        SendMessageAnimationActions.performWithoutAnimation {
          let hadScrollInFlight = collectionView.isSendAnimationScrollInFlight
          let stoppedComposeInset = collectionView.stopComposeInsetAnimationAtPresentation()
          if hadScrollInFlight {
            collectionView.cancelSendAnimationScrollAnimations()
          }
          let appliedDeferredComposeInset = collectionView.applyDeferredComposeInsetForPendingSendAnimationIfNeeded(
            reason: "post-apply"
          )
          if stoppedComposeInset || hadScrollInFlight || appliedDeferredComposeInset {
            SendMessageAnimationDiagnostics.debug(
              "list anchor-scroll-state-stopped compose=\(stoppedComposeInset) scroll=\(hadScrollInFlight) deferredCompose=\(appliedDeferredComposeInset) offsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
            )
          }
          collectionView.layoutIfNeeded()
          self.restoreSendAnimationContentAnchor(
            contentAnchor,
            in: collectionView
          )
        }

        let scrollPlan = collectionView.makeSendAnimationScrollPlanToBottom()
        SendMessageAnimationDiagnostics.event(
          "post-apply target-start remainingItems=\(remaining.items.count) remainingIdentities=\(remaining.identities.count) offsetY=\(String(format: "%.1f", collectionView.contentOffset.y)) scrollDy=\(scrollPlan.map { String(format: "%.1f", $0.modelContentOffsetYDeltaToTarget) } ?? "nil") targetOffsetY=\(scrollPlan.map { String(format: "%.1f", $0.targetOffset.y) } ?? "nil")"
        )

        retargetActiveSendAnimationTargetsAfterApply(
          excluding: identities,
          finalizedScrollPlan: scrollPlan,
          collectionView: collectionView
        )

        var consumedItems = Set<MessageListItem>()
        var consumedIdentities = Set<SendMessageAnimationIdentity>()

        for item in remaining.items {
          guard let identity = sendAnimationIdentity(for: item) else {
            consumedItems.insert(item)
            continue
          }

          guard let indexPath = dataSource.indexPath(for: item),
                let cell = collectionView.cellForItem(at: indexPath) as? MessageCollectionViewCell
          else {
            consumedItems.insert(item)
            consumedIdentities.insert(identity)
            sendAnimationCoordinator?.cancel(identity: identity)
            SendMessageAnimationDiagnostics.event(
              "post-apply target-start unavailable-cell item=\(item) random=\(identity.randomId)"
            )
            continue
          }

          if beginSendAnimationTargetIfPossible(
            for: item,
            at: indexPath,
            cell: cell,
            finalizedScrollPlan: scrollPlan,
            fallbackAnimatesInsertion: false
          ) {
            consumedItems.insert(item)
            consumedIdentities.insert(identity)
            continue
          }

          consumedItems.insert(item)
          consumedIdentities.insert(identity)
          cell.revealSendAnimationTarget()
          sendAnimationCoordinator?.cancel(identity: identity)
          SendMessageAnimationDiagnostics.event(
            "post-apply target-start fallback-reveal item=\(item) random=\(identity.randomId)"
          )
        }

        sendAnimationListTransaction.subtract(
          SendMessageAnimationListRemainder(
            items: consumedItems,
            identities: consumedIdentities
          )
        )
      }

      if Thread.isMainThread {
        beginTargets()
      } else {
        DispatchQueue.main.async(execute: beginTargets)
      }
    }

    private func applyDeferredComposeInsetAfterFallbackInsert(
      collectionView: MessagesCollectionView,
      contentAnchor: SendAnimationContentAnchor?
    ) {
      SendMessageAnimationActions.performWithoutAnimation {
        let hadScrollInFlight = collectionView.isSendAnimationScrollInFlight
        let stoppedComposeInset = collectionView.stopComposeInsetAnimationAtPresentation()
        if hadScrollInFlight {
          collectionView.cancelSendAnimationScrollAnimations()
        }
        let appliedDeferredComposeInset = collectionView.applyDeferredComposeInsetForPendingSendAnimationIfNeeded(
          reason: "post-apply-no-preview"
        )
        if stoppedComposeInset || hadScrollInFlight || appliedDeferredComposeInset {
          SendMessageAnimationDiagnostics.debug(
            "list fallback-anchor-scroll-state-stopped compose=\(stoppedComposeInset) scroll=\(hadScrollInFlight) deferredCompose=\(appliedDeferredComposeInset) offsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
          )
        }
        collectionView.layoutIfNeeded()
        restoreSendAnimationContentAnchor(
          contentAnchor,
          in: collectionView
        )
      }

      guard let scrollPlan = collectionView.makeSendAnimationScrollPlanToBottom() else {
        SendMessageAnimationDiagnostics.event(
          "post-apply deferred-compose-only no-scroll-needed offsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
        )
        return
      }

      SendMessageAnimationDiagnostics.event(
        "post-apply deferred-compose-only scrollDy=\(String(format: "%.1f", scrollPlan.modelContentOffsetYDeltaToTarget)) targetOffsetY=\(String(format: "%.1f", scrollPlan.targetOffset.y))"
      )
      SendMessageAnimationActions.performWithAnimationsEnabled(
        reason: "deferred-compose-only-scroll"
      ) {
        collectionView.animateSendAnimationScrollToBottom(
          targetOffset: scrollPlan.targetOffset,
          duration: SendMessageAnimationTiming.duration
        )
      }
    }

    private func retargetActiveSendAnimationTargetsAfterApply(
      excluding identities: Set<SendMessageAnimationIdentity>,
      finalizedScrollPlan: SendMessageAnimationScrollPlan?,
      collectionView: MessagesCollectionView
    ) {
      guard let activeIdentitiesByStableMessageId = sendAnimationCoordinator?
        .activeAnimatingIdentitiesByStableMessageId(excluding: identities),
        !activeIdentitiesByStableMessageId.isEmpty
      else {
        return
      }

      let scrollProjectionY = finalizedScrollPlan?.modelContentOffsetYDeltaToTarget ?? 0
      let durationFromPlan: (SendMessageAnimationIdentity) -> TimeInterval = { [weak self] identity in
        if finalizedScrollPlan != nil {
          return self?.sendAnimationCoordinator?.retargetDuration(for: identity)
            ?? SendMessageAnimationTiming.duration
        }
        return SendMessageAnimationTiming.duration
      }

      var attemptedCount = 0
      var retargetedCount = 0
      var unavailableCount = 0

      for (stableMessageId, identity) in activeIdentitiesByStableMessageId.sorted(by: { $0.key < $1.key }) {
        attemptedCount += 1
        let item = MessageListItem.message(id: stableMessageId)
        guard let message = message(for: item),
              let indexPath = dataSource.indexPath(for: item),
              let cell = collectionView.cellForItem(at: indexPath) as? MessageCollectionViewCell
        else {
          unavailableCount += 1
          SendMessageAnimationDiagnostics.debug(
            "retarget active-skip unavailable-cell stable=\(stableMessageId) random=\(identity.randomId) scrollWindowDy=\(String(format: "%.1f", scrollProjectionY))"
          )
          continue
        }

        guard let target = makeSendAnimationTarget(
          for: item,
          message: message,
          identity: identity,
          cell: cell,
          scrollProjectionY: scrollProjectionY
        ) else {
          unavailableCount += 1
          cell.revealSendAnimationTarget()
          sendAnimationCoordinator?.cancel(identity: identity)
          SendMessageAnimationDiagnostics.event(
            "retarget active-cancel unavailable-target stable=\(stableMessageId) random=\(identity.randomId) scrollWindowDy=\(String(format: "%.1f", scrollProjectionY))"
          )
          continue
        }

        let duration = durationFromPlan(identity)
        let didRetarget = sendAnimationCoordinator?.retargetIfPossible(
          target: target,
          duration: duration,
          revealTarget: { [weak self, weak cell] latestTarget in
            guard let cell,
                  Self.cell(cell, matchesSendAnimationTarget: latestTarget)
            else {
              return
            }
            cell.revealSendAnimationTarget()
            self?.logFinalSendAnimationTargetFrame(
              target: latestTarget,
              expectedBubbleFrameInWindow: latestTarget.bubbleFrameInWindow,
              expectedTextFrameInWindow: latestTarget.textFrameInWindow,
              cell: cell
            )
          }
        ) == true

        if didRetarget {
          retargetedCount += 1
        } else {
          cell.revealSendAnimationTarget()
          sendAnimationCoordinator?.cancel(identity: identity)
          SendMessageAnimationDiagnostics.event(
            "retarget active-cancel failed stable=\(stableMessageId) random=\(identity.randomId) scrollWindowDy=\(String(format: "%.1f", scrollProjectionY))"
          )
        }
      }

      SendMessageAnimationDiagnostics.event(
        "retarget active-summary attempted=\(attemptedCount) retargeted=\(retargetedCount) unavailable=\(unavailableCount) scrollDy=\(String(format: "%.1f", scrollProjectionY))"
      )
    }

    private func makeSendAnimationContentAnchor(
      in snapshot: NSDiffableDataSourceSnapshot<MessageListSectionID, MessageListItem>,
      sectionId: MessageListSectionID,
      collectionView: MessagesCollectionView
    ) -> SendAnimationContentAnchor? {
      collectionView.layoutIfNeeded()

      let sectionItems = snapshot.itemIdentifiers(inSection: sectionId)
      guard let item = sectionItems.first else {
        SendMessageAnimationDiagnostics.debug(
          "list anchor-capture skipped reason=empty-section offsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
        )
        return nil
      }

      guard let frameInWindow = sendAnimationAnchorFrameInWindow(
        for: item,
        in: collectionView
      ) else {
        SendMessageAnimationDiagnostics.debug(
          "list anchor-capture skipped item=\(item) reason=missing-frame offsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
        )
        return nil
      }

      SendMessageAnimationDiagnostics.debug(
        "list anchor-capture item=\(item) frame=[\(SendMessageAnimationDiagnostics.rect(frameInWindow))] offsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
      )

      return SendAnimationContentAnchor(
        item: item,
        frameInWindow: frameInWindow,
        contentOffset: collectionView.contentOffset
      )
    }

    private func restoreSendAnimationContentAnchor(
      _ anchor: SendAnimationContentAnchor?,
      in collectionView: MessagesCollectionView
    ) {
      guard let anchor else {
        SendMessageAnimationDiagnostics.debug(
          "list anchor-restore skipped reason=nil offsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
        )
        return
      }

      guard let currentFrameInWindow = sendAnimationAnchorFrameInWindow(
        for: anchor.item,
        in: collectionView
      ) else {
        SendMessageAnimationDiagnostics.debug(
          "list anchor-restore skipped item=\(anchor.item) reason=missing-frame oldOffsetY=\(String(format: "%.1f", anchor.contentOffset.y)) currentOffsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
        )
        return
      }

      let visualDeltaY = anchor.frameInWindow.minY - currentFrameInWindow.minY
      guard abs(visualDeltaY) > 0.5 else {
        SendMessageAnimationDiagnostics.debug(
          "list anchor-restore unchanged item=\(anchor.item) oldY=\(String(format: "%.1f", anchor.frameInWindow.minY)) currentY=\(String(format: "%.1f", currentFrameInWindow.minY)) oldOffsetY=\(String(format: "%.1f", anchor.contentOffset.y)) currentOffsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
        )
        return
      }

      let isVerticallyFlipped = collectionView.transform.d < 0
      let offsetDeltaY = isVerticallyFlipped ? visualDeltaY : -visualDeltaY
      let requestedOffset = CGPoint(
        x: collectionView.contentOffset.x,
        y: collectionView.contentOffset.y + offsetDeltaY
      )
      let restoredOffset = collectionView.clampedSendAnimationContentOffset(requestedOffset)
      let beforeOffsetY = collectionView.contentOffset.y

      collectionView.setContentOffset(restoredOffset, animated: false)
      collectionView.layoutIfNeeded()

      let restoredFrameInWindow = sendAnimationAnchorFrameInWindow(
        for: anchor.item,
        in: collectionView
      )
      let residualY = restoredFrameInWindow.map {
        $0.minY - anchor.frameInWindow.minY
      } ?? 0

      SendMessageAnimationDiagnostics.event(
        "list anchor-restore item=\(anchor.item) flipped=\(isVerticallyFlipped) oldY=\(String(format: "%.1f", anchor.frameInWindow.minY)) currentY=\(String(format: "%.1f", currentFrameInWindow.minY)) visualDeltaY=\(String(format: "%.1f", visualDeltaY)) oldOffsetY=\(String(format: "%.1f", anchor.contentOffset.y)) beforeOffsetY=\(String(format: "%.1f", beforeOffsetY)) requestedOffsetY=\(String(format: "%.1f", requestedOffset.y)) restoredOffsetY=\(String(format: "%.1f", restoredOffset.y)) residualY=\(String(format: "%.1f", residualY))"
      )
    }

    private func sendAnimationAnchorFrameInWindow(
      for item: MessageListItem,
      in collectionView: UICollectionView
    ) -> CGRect? {
      guard let window = collectionView.window,
            let indexPath = dataSource.indexPath(for: item)
      else {
        return nil
      }

      if let cell = collectionView.cellForItem(at: indexPath) {
        return cell.convert(cell.bounds, to: window)
      }

      guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
        return nil
      }

      return collectionView.convert(attributes.frame, to: window)
    }

    private func makeSendAnimationTarget(
      for item: MessageListItem,
      message: FullMessage,
      identity: SendMessageAnimationIdentity,
      cell: MessageCollectionViewCell,
      scrollProjectionY: CGFloat
    ) -> SendMessageAnimationTarget? {
      SendMessageAnimationActions.performWithoutAnimation {
        currentCollectionView?.layoutIfNeeded()
        (currentCollectionView as? MessagesCollectionView)?.syncBubbleGradient(for: cell)
        cell.stabilizeSendAnimationTargetForSnapshot()
      }

      guard let presentation = cell.sendAnimationTargetPresentationInWindow() else {
        SendMessageAnimationDiagnostics.event(
          "target unavailable item=\(item) stable=\(message.id) preparedTarget=\(cell.isPreparedForSendAnimationTarget)"
        )
        return nil
      }

      let projected = SendMessageAnimationProjectedTarget(
        presentation: presentation,
        scrollWindowY: scrollProjectionY
      )

      SendMessageAnimationDiagnostics.debug(
        "target frames item=\(item) stable=\(message.id) mode=\(projected.mode) cell=[\(SendMessageAnimationDiagnostics.rect(projected.originalCellFrame))] bubble=[\(SendMessageAnimationDiagnostics.rect(projected.originalBubbleFrame))] text=[\(SendMessageAnimationDiagnostics.rect(projected.originalTextFrame))] projectedCell=[\(SendMessageAnimationDiagnostics.rect(projected.cellFrame))] projectedBubble=[\(SendMessageAnimationDiagnostics.rect(projected.bubbleFrame))] projectedText=[\(SendMessageAnimationDiagnostics.rect(projected.textFrame))] scrollWindowDy=\(String(format: "%.1f", scrollProjectionY)) textInBubble=[\(SendMessageAnimationDiagnostics.rect(presentation.textFrameInBubble))] baselineY=\(String(format: "%.1f", projected.textFirstBaselineYInWindow)) baselineBubbleY=\(String(format: "%.1f", presentation.textFirstBaselineYInBubble)) targetSnapshot=\(type(of: presentation.bubbleSnapshotView))"
      )

      return SendMessageAnimationTarget(
        identity: identity,
        messageStableId: message.id,
        bubbleFrameInWindow: projected.bubbleFrame,
        textFrameInWindow: projected.textFrame,
        bubbleSnapshotView: presentation.bubbleSnapshotView,
        textFrameInBubble: presentation.textFrameInBubble,
        textFirstBaselineYInWindow: projected.textFirstBaselineYInWindow,
        textFirstBaselineYInBubble: presentation.textFirstBaselineYInBubble,
        bubbleTailSide: cell.bubbleTailSideForSendAnimation()
      )
    }

    private func makeSendAnimationTargetStart(
      for item: MessageListItem,
      at _: IndexPath,
      cell: MessageCollectionViewCell,
      finalizedScrollPlan: SendMessageAnimationScrollPlan? = nil
    ) -> SendMessageAnimationTargetStart? {
      guard let message = message(for: item),
            let identity = sendAnimationCoordinator?.pendingIdentity(for: message)
      else {
        return nil
      }

      var scrollProjectionY: CGFloat = 0
      var scrollPlanToStart: SendMessageAnimationScrollPlan?

      if let finalizedScrollPlan {
        scrollProjectionY = finalizedScrollPlan.modelContentOffsetYDeltaToTarget
        scrollPlanToStart = finalizedScrollPlan
        let duration = sendAnimationCoordinator?.retargetDuration(for: identity)
          ?? SendMessageAnimationTiming.duration
        SendMessageAnimationDiagnostics.event(
          "target scroll-finalized item=\(item) modelContentDy=\(String(format: "%.1f", finalizedScrollPlan.modelContentOffsetYDeltaToTarget)) presentationContentDy=\(finalizedScrollPlan.presentationContentOffsetYDeltaToTarget.map { String(format: "%.1f", $0) } ?? "nil") targetOffsetY=\(String(format: "%.1f", finalizedScrollPlan.targetOffset.y)) duration=\(String(format: "%.3f", duration)) windowDy=\(String(format: "%.1f", scrollProjectionY))"
        )
      } else if isPendingSendAnimationScrollTarget(item: item, identity: identity),
                let collectionView = currentCollectionView as? MessagesCollectionView
      {
        if collectionView.isSendAnimationScrollInFlight {
          if let scrollPlan = collectionView.activeSendAnimationScrollPlanToTarget() {
            scrollProjectionY = scrollPlan.presentationContentOffsetYDeltaToTarget
              ?? scrollPlan.modelContentOffsetYDeltaToTarget
            SendMessageAnimationDiagnostics.debug(
              "target scroll-active-project item=\(item) modelContentDy=\(String(format: "%.1f", scrollPlan.modelContentOffsetYDeltaToTarget)) presentationContentDy=\(scrollPlan.presentationContentOffsetYDeltaToTarget.map { String(format: "%.1f", $0) } ?? "nil") targetOffsetY=\(String(format: "%.1f", scrollPlan.targetOffset.y)) modelOffsetY=\(String(format: "%.1f", collectionView.contentOffset.y)) windowDy=\(String(format: "%.1f", scrollProjectionY))"
            )
          } else {
            SendMessageAnimationDiagnostics.debug(
              "target scroll-adjust-active-none item=\(item) offsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
            )
          }
        } else if let scrollPlan = collectionView.makeSendAnimationScrollPlanToBottom() {
          let duration = sendAnimationCoordinator?.retargetDuration(for: identity)
            ?? SendMessageAnimationTiming.duration
          let presentationOffsetY = collectionView.layer.presentation()?.bounds.origin.y
          let presentationAwarePlan = presentationOffsetY.flatMap {
            collectionView.makeSendAnimationScrollPlanToBottom(currentOffsetY: $0)
          } ?? scrollPlan
          if presentationAwarePlan.presentationContentOffsetYDeltaToTarget != nil,
             collectionView.stopComposeInsetAnimationAtPresentation()
          {
            SendMessageAnimationDiagnostics.debug(
              "target scroll-retarget-compose-presentation item=\(item) presentationOffsetY=\(String(format: "%.1f", presentationOffsetY ?? collectionView.contentOffset.y)) modelOffsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
            )
          }
          if let retargetedPlan = collectionView.makeSendAnimationScrollPlanToBottom() {
            scrollProjectionY = presentationAwarePlan.presentationContentOffsetYDeltaToTarget
              ?? retargetedPlan.modelContentOffsetYDeltaToTarget
            scrollPlanToStart = retargetedPlan
          } else {
            scrollProjectionY = 0
            scrollPlanToStart = nil
          }
          let loggedScrollPlan = scrollPlanToStart ?? presentationAwarePlan
          SendMessageAnimationDiagnostics.event(
            "target scroll-project-before-start item=\(item) modelContentDy=\(String(format: "%.1f", loggedScrollPlan.modelContentOffsetYDeltaToTarget)) presentationContentDy=\(presentationAwarePlan.presentationContentOffsetYDeltaToTarget.map { String(format: "%.1f", $0) } ?? "nil") targetOffsetY=\(String(format: "%.1f", loggedScrollPlan.targetOffset.y)) duration=\(String(format: "%.3f", duration)) windowDy=\(String(format: "%.1f", scrollProjectionY))"
          )
        } else {
          SendMessageAnimationDiagnostics.debug(
            "target scroll-adjust-none item=\(item) offsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
          )
        }
      }

      guard let target = makeSendAnimationTarget(
        for: item,
        message: message,
        identity: identity,
        cell: cell,
        scrollProjectionY: scrollProjectionY
      ) else {
        return nil
      }

      return SendMessageAnimationTargetStart(
        target: target,
        scrollTargetOffset: scrollPlanToStart?.targetOffset,
        scrollDuration: scrollPlanToStart.map { _ in
          sendAnimationCoordinator?.retargetDuration(for: identity)
            ?? SendMessageAnimationTiming.duration
        }
      )
    }

    private func logFinalSendAnimationTargetFrame(
      target: SendMessageAnimationTarget,
      expectedBubbleFrameInWindow: CGRect,
      expectedTextFrameInWindow: CGRect,
      cell: MessageCollectionViewCell?
    ) {
      #if DEBUG || DEBUG_BUILD
      guard let cell,
            Self.cell(cell, matchesSendAnimationTarget: target),
            let geometry = cell.sendAnimationTargetGeometryInWindow()
      else {
        SendMessageAnimationDiagnostics.event(
          "target final-frame-unavailable stable=\(target.messageStableId) random=\(target.identity.randomId) temp=\(target.identity.temporaryMessageId)"
        )
        return
      }

      SendMessageAnimationDiagnostics.event(
        "target final-frame stable=\(target.messageStableId) actualStable=\(cell.message?.id.description ?? "nil") random=\(cell.message?.message.randomId.map(String.init) ?? "nil") temp=\(target.identity.temporaryMessageId) cell=[\(SendMessageAnimationDiagnostics.rect(geometry.cellFrame))] bubble=[\(SendMessageAnimationDiagnostics.rect(geometry.bubbleFrame))] text=[\(SendMessageAnimationDiagnostics.rect(geometry.textFrame))] baselineY=\(String(format: "%.1f", geometry.textFirstBaselineYInWindow)) expectedBubble=[\(SendMessageAnimationDiagnostics.rect(expectedBubbleFrameInWindow))] expectedText=[\(SendMessageAnimationDiagnostics.rect(expectedTextFrameInWindow))] expectedBaselineY=\(String(format: "%.1f", target.textFirstBaselineYInWindow)) bubbleDelta=[\(SendMessageAnimationGeometry.rectDelta(from: expectedBubbleFrameInWindow, to: geometry.bubbleFrame))] textDelta=[\(SendMessageAnimationGeometry.rectDelta(from: expectedTextFrameInWindow, to: geometry.textFrame))] baselineDelta=\(String(format: "%.1f", geometry.textFirstBaselineYInWindow - target.textFirstBaselineYInWindow))"
      )
      #endif
    }

    private func finishPendingSendAnimationScrollIfNeeded(
      _ items: Set<MessageListItem>,
      identities: Set<SendMessageAnimationIdentity>,
      collectionView: MessagesCollectionView
    ) {
      let remaining = sendAnimationListTransaction.remainder(
        for: items,
        identities: identities
      )
      guard !remaining.isEmpty else {
        if collectionView.isSendAnimationScrollInFlight {
          SendMessageAnimationDiagnostics.debug(
            "list scroll-completion skipped consumed=true scroll=in-flight items=\(items.count) identities=\(identities.count)"
          )
          return
        }

        SendMessageAnimationDiagnostics.debug(
          "list scroll-completion skipped consumed=true scroll=not-starting-late items=\(items.count) identities=\(identities.count)"
        )
        return
      }

      let remainingIdentityCandidates = Set(
        remaining.items.compactMap(sendAnimationIdentity(for:))
      ).union(remaining.identities)
      let duration = remainingIdentityCandidates
        .compactMap { sendAnimationCoordinator?.retargetDuration(for: $0) }
        .max() ?? SendMessageAnimationTiming.duration
      if collectionView.isSendAnimationScrollInFlight {
        SendMessageAnimationDiagnostics.debug(
          "list scroll-completion in-flight items=\(remaining.items.count) identities=\(remaining.identities.count) offsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
        )
      } else if let scrollPlan = collectionView.makeSendAnimationScrollPlanToBottom() {
        SendMessageAnimationDiagnostics.event(
          "list scroll-completion coordinated-fallback items=\(remaining.items.count) identities=\(remaining.identities.count) modelContentDy=\(String(format: "%.1f", scrollPlan.modelContentOffsetYDeltaToTarget)) targetOffsetY=\(String(format: "%.1f", scrollPlan.targetOffset.y)) duration=\(String(format: "%.3f", duration))"
        )
        SendMessageAnimationActions.performWithAnimationsEnabled(
          reason: "completion-scroll-fallback"
        ) {
          collectionView.animateSendAnimationScrollToBottom(
            targetOffset: scrollPlan.targetOffset,
            duration: duration
          )
        }
      } else {
        SendMessageAnimationDiagnostics.debug(
          "list scroll-completion no-scroll-needed items=\(remaining.items.count) identities=\(remaining.identities.count) offsetY=\(String(format: "%.1f", collectionView.contentOffset.y))"
        )
      }

      SendMessageAnimationDiagnostics.debug(
        "list scroll-completion pending-preserved items=\(remaining.items.count) identities=\(remaining.identities.count)"
      )
      DispatchQueue.main.asyncAfter(
        deadline: .now() + SendMessageAnimationTiming.duration + 0.4
      ) { [weak self] in
        guard let self else { return }
        let stale = sendAnimationListTransaction.remainder(
          for: remaining.items,
          identities: remaining.identities
        )
        guard !stale.isEmpty else { return }
        sendAnimationListTransaction.subtract(stale)
        SendMessageAnimationDiagnostics.event(
          "list scroll-completion cleanup-stale items=\(stale.items.count) identities=\(stale.identities.count)"
        )
      }
    }

    func numberOfSections() -> Int {
      listSections.count
    }

    func numberOfItems(in section: Int) -> Int {
      listSection(at: section)?.items.count ?? 0
    }

    init(
      peerId: Peer,
      chatId: Int64,
      spaceId: Int64?,
      collapsedMaxId: Int64? = nil,
      isPreview: Bool = false,
      sendAnimationCoordinator: SendMessageAnimationCoordinator? = nil,
      theme: IOSThemeSnapshot,
      messageViewImplementation: MessageViewImplementation,
      viewModel: MessagesSectionedViewModel? = nil
    ) {
      self.peerId = peerId
      self.chatId = chatId
      self.spaceId = spaceId
      self.isPreview = isPreview
      self.theme = theme
      self.messageViewImplementation = messageViewImplementation
      self.sendAnimationCoordinator = sendAnimationCoordinator
      self.viewModel = viewModel ?? MessagesSectionedViewModel(
        peer: peerId,
        reversed: true,
        collapsedMaxId: collapsedMaxId
      )
      translationViewModel = TranslationViewModel(peerId: peerId)

      super.init()
      rebuildListSections()

      self.viewModel.observe { [weak self] update in
        guard let self else { return }
        applyUpdate(update)
        if !isPreview {
          handleTranslationForUpdate(update)
          ensureThreadAnchorCachedIfNeeded()
        }
      }

      if !isPreview {
        // Subscribe to translation state changes
        TranslationState.shared.subject
          .sink { [weak self] peer, _ in
            guard let self, peer == self.peerId else { return }
            var snapshot = dataSource.snapshot()
            let ids = messages.map { MessageListItem.message(id: $0.id) }
            // Safety check: only reconfigure items that actually exist in the snapshot
            let existingIds = ids.filter { snapshot.itemIdentifiers.contains($0) }
            if !existingIds.isEmpty {
              snapshot.reconfigureItems(existingIds)
              safeApplySnapshot(snapshot, animatingDifferences: true)
            }
          }
          .store(in: &cancellables)

        // Setup NotionTaskManager delegate
        setupNotionTaskManager()
        ensureThreadAnchorCachedIfNeeded()
      }
    }

    func applyTheme(_ theme: IOSThemeSnapshot) {
      guard self.theme != theme else { return }
      self.theme = theme
      guard let collectionView = currentCollectionView as? MessagesCollectionView else { return }
      for case let cell as MessageCollectionViewCell in collectionView.visibleCells {
        cell.applyTheme(theme)
      }
    }

    func dispose() {
      if let animator = v2GeometryAnimator {
        v2GeometryAnimator = nil
        if animator.state == .active {
          animator.stopAnimation(false)
          animator.finishAnimation(at: .end)
        }
      }
      for transition in v2GeometryTransitions { transition.finish() }
      v2GeometryTransitions.removeAll()
      olderLoadTask?.cancel()
      olderLoadTask = nil
      olderHistoryPagination.reset()
      newerLoadTask?.cancel()
      newerLoadTask = nil
      threadAnchorFetchTask?.cancel()
      threadAnchorFetchTask = nil
      mediaWarmupTask?.cancel()
      mediaWarmupTask = nil
      let thumbnailWarmups = mediaWarmups
      mediaWarmups.removeAll()
      Task {
        for warmup in thumbnailWarmups {
          await InlineTinyThumbnailPrewarmer.cancel(warmup)
        }
      }
      viewModel.dispose()
      cancellables.forEach { $0.cancel() }
      cancellables.removeAll()
      detachAvatarOverlay()
    }

    private func setupNotionTaskManager() {
      NotionTaskManager.shared.delegate = self
      Task {
        let scopedSpaceId = peerId.isThread ? spaceId.validSpaceId : nil
        do {
          let integrations = try await InlineRPCClient.shared.integrations(
            userID: Auth.shared.getCurrentUserId() ?? 0,
            spaceID: scopedSpaceId
          )

          await NotionTaskManager.shared.checkIntegrationAccess(
            peerId: peerId,
            spaceId: scopedSpaceId,
            integrations: integrations
          )

          DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let hasLinearConnected = peerId.isThread
              ? integrations.hasLinearConnected
              : (integrations.linearSpaces?.isEmpty == false)
            self.hasLinearConnected = hasLinearConnected
            linearTeamId = integrations.linearTeamId
          }
        } catch {
          NotionTaskManager.shared.clearIntegrationAccess()
          DispatchQueue.main.async { [weak self] in
            self?.hasLinearConnected = false
            self?.linearTeamId = nil
          }
        }
      }
    }

    private struct ThreadAnchorFetchRequest {
      let parentPeer: Peer
      let parentMessageId: Int64
    }

    private func ensureThreadAnchorCachedIfNeeded() {
      guard !isPreview else { return }
      guard threadAnchorFetchTask == nil else { return }
      guard !didExhaustThreadAnchorFetch else { return }
      guard viewModel.threadAnchor == nil else { return }
      guard case .thread = peerId else { return }

      threadAnchorFetchTask = Task { @MainActor [weak self] in
        guard let self else { return }
        defer { self.threadAnchorFetchTask = nil }

        for attempt in 1 ... 3 {
          guard !Task.isCancelled else { return }
          guard viewModel.threadAnchor == nil else { return }
          guard let request = await Self.threadAnchorFetchRequest(peer: peerId) else {
            await Self.sleepBeforeThreadAnchorRetry(attempt: attempt)
            continue
          }

          do {
            _ = try await Api.realtime.send(.getMessages(
              peer: request.parentPeer,
              messageIds: [request.parentMessageId]
            ))
          } catch {
            Log.shared.error("Failed to fetch reply thread anchor message", error: error)
            await Self.sleepBeforeThreadAnchorRetry(attempt: attempt)
            continue
          }

          guard !Task.isCancelled else { return }
          if viewModel.reloadThreadAnchorFromLocal() {
            setInitialData(animated: false)
            return
          }

          await Self.sleepBeforeThreadAnchorRetry(attempt: attempt)
        }

        didExhaustThreadAnchorFetch = true
      }
    }

    private static func sleepBeforeThreadAnchorRetry(attempt: Int) async {
      guard attempt < 3 else { return }
      try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
    }

    private static func threadAnchorFetchRequest(peer: Peer) async -> ThreadAnchorFetchRequest? {
      guard case let .thread(threadId) = peer else { return nil }

      do {
        return try await AppDatabase.shared.reader.read { db in
          guard let chat = try Chat.fetchOne(db, id: threadId),
                let parentChatId = chat.parentChatId,
                let parentMessageId = chat.parentMessageId,
                let parentChat = try Chat.fetchOne(db, id: parentChatId)
          else {
            return nil
          }

          return ThreadAnchorFetchRequest(
            parentPeer: parentChat.peerId.toPeer(),
            parentMessageId: parentMessageId
          )
        }
      } catch {
        Log.shared.error("Failed to load reply thread anchor metadata", error: error)
        return nil
      }
    }

    private var hasLinearConnected: Bool = false
    private var linearTeamId: String?

    private func isMessagePinned(_ message: Message) -> Bool {
      message.pinned == true
    }

    private func togglePinMessage(_ message: Message, unpin: Bool) {
      Task { @MainActor in
        do {
          let peer = chatPeerId(for: message)
          _ = try await Api.realtime.send(.pinMessage(peer: peer, messageId: message.messageId, unpin: unpin))
        } catch {
          Log.shared.error("Failed to update pinned message", error: error)
        }
      }
    }

    private func chatPeerId(for message: Message) -> Peer {
      message.peerId
    }

    func setupDataSource(_ collectionView: UICollectionView) {
      currentCollectionView = collectionView

      let cellRegistration = UICollectionView.CellRegistration<
        MessageCollectionViewCell,
        MessageListItem
      > { [weak self] cell, indexPath, item in
        guard let self, let model = model(for: item)
        else {
          return
        }

        guard case let .message(message, displayMode) = model.content else {
          return
        }
        let firstInGroup = item.isThreadAnchor ? true : isFirstInGroup(at: indexPath)
        let lastInGroup = item.isThreadAnchor ? true : isLastInGroup(at: indexPath)
        let isPendingAppearingItem = pendingAppearingItems.contains(item)
        let sendTargetIdentity = sendAnimationIdentity(for: item)
        let isPendingSendAnimationTarget = sendTargetIdentity.map {
          self.sendAnimationListTransaction.contains(item: item, identity: $0)
        } ?? false
        let isAnimatingSendAnimationTarget = sendTargetIdentity.map {
          self.sendAnimationCoordinator?.isAnimating(identity: $0) == true
        } ?? false
        let shouldPrepareSendAnimationTarget = isPendingAppearingItem && isPendingSendAnimationTarget
        let currentSpaceId = spaceId
        // A fast acknowledgement can arrive before the hidden send-animation target is built.
        // Preserve the clock until reveal so the same sending-to-sent transition remains visible.
        let shouldStartFromSendingStatus = sendTargetIdentity != nil && message.message.status == .sent
        let initialMetadataStatus: MessageSendingStatus? = shouldStartFromSendingStatus ? .sending : nil
        let v2GeometryChangeHandler: ((
          MessageCollectionViewCell,
          MessageBubbleLayoutV2,
          MessageBubbleLayoutV2
        ) -> Void)? = messageViewImplementation == .v2 ? makeV2GeometryChangeHandler() : nil

        cell.grabOverlappingAvatar = { [weak self] sourceView in
          self?.avatarOverlayController.grabAvatar(overlapping: sourceView)
        }

        let configureCell = {
          cell.onV2GeometryChange = v2GeometryChangeHandler
          cell.configure(
            with: message,
            firstInGroup: firstInGroup,
            lastInGroup: lastInGroup,
            spaceId: currentSpaceId,
            collectionWidth: self.currentCollectionView?.bounds.width ?? 0,
            displayMode: displayMode,
            animateTail: true,
            theme: self.theme,
            initialMetadataStatus: initialMetadataStatus,
            messageViewImplementation: self.messageViewImplementation
          )
        }

        if shouldPrepareSendAnimationTarget || isAnimatingSendAnimationTarget {
          SendMessageAnimationActions.performWithoutAnimation {
            configureCell()
            if isAnimatingSendAnimationTarget {
              SendMessageAnimationDiagnostics.debug(
                "cell keep-hidden-animating-target item=\(item) random=\(sendTargetIdentity.map { String($0.randomId) } ?? "nil")"
              )
            } else {
              SendMessageAnimationDiagnostics.debug(
                "cell prepare-target item=\(item) random=\(sendTargetIdentity.map { String($0.randomId) } ?? "nil")"
              )
            }
            cell.prepareSendAnimationTarget()
            if shouldPrepareSendAnimationTarget {
              cell.stabilizeSendAnimationTargetForSnapshot()
            }
          }
        } else {
          configureCell()
          if isPendingAppearingItem {
            SendMessageAnimationDiagnostics.debug(
              "cell prepare-default-no-identity item=\(item) stable=\(message.id) msgId=\(message.message.messageId) random=\(message.message.randomId.map(String.init) ?? "nil") textLen=\(message.message.text?.count ?? 0)"
            )
            cell.prepareInsertionAnimation()
          } else {
            cell.alpha = 1
            cell.revealSendAnimationTarget()
          }
        }

        cell.onUserTap = { userId in
          // Navigate to user chat using notification center to bridge back to SwiftUI
          NotificationCenter.default.post(
            name: Notification.Name("NavigateToUser"),
            object: nil,
            userInfo: ["userId": userId]
          )
        }

        cell.onPhotoTap = { [weak self] message, sourceView, sourceImage, url in
          self?.presentPhotoGallery(
            for: message,
            sourceView: sourceView,
            sourceImage: sourceImage,
            imageURL: url
          )
        }
      }

      let separatorRegistration = UICollectionView.CellRegistration<
        MessageListSeparatorCell,
        MessageListItem
      > { [weak self] cell, _, item in
        guard let self, let model = model(for: item) else { return }

        switch model.content {
          case let .unreadSeparator(title):
            cell.configure(title: title)
          case let .collapsedHistory(title):
            cell.configure(title: title, showsLines: false) { [weak self] in
              guard let collectionView = self?.currentCollectionView as? MessagesCollectionView else { return }
              Task { @MainActor in
                do {
                  try await collectionView.collapseHistory(maxID: nil)
                } catch {
                  Log.shared.error("Failed to show collapsed history", error: error)
                }
              }
            }
          case .message:
            break
        }
      }

      dataSource = UICollectionViewDiffableDataSource<MessageListSectionID, MessageListItem>(
        collectionView: collectionView
      ) { collectionView, indexPath, item in
        switch item {
          case .message, .threadAnchor:
            collectionView.dequeueConfiguredReusableCell(
              using: cellRegistration,
              for: indexPath,
              item: item
            )
          case .unreadSeparator, .collapsedHistory:
            collectionView.dequeueConfiguredReusableCell(
              using: separatorRegistration,
              for: indexPath,
              item: item
            )
        }
      }

      // Configure supplementary view provider for date separators
      dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
        guard let self else { return nil }

        if kind == UICollectionView.elementKindSectionFooter {
          guard let footerView = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: DateSeparatorView.reuseIdentifier,
            for: indexPath
          ) as? DateSeparatorView else {
            return nil
          }

          // Safely get section with bounds checking
          if let section = listSection(at: indexPath.section) {
            let sectionID = section.id
            footerView.configure(
              with: section.dayString ?? "",
              onTap: { [weak self] in
                self?.scrollToFirstMessage(in: sectionID)
              },
              onInteractionChanged: { [weak self] isInteracting in
                self?.dateSeparatorInteractionChanged(isInteracting)
              }
            )
          } else {
            // Fallback for invalid section
            footerView.configure(with: "")
          }

          return footerView
        }

        return nil
      }

      // Set initial data after configuring the data source
      setInitialData()
    }

    private func makeV2GeometryChangeHandler() -> (
      MessageCollectionViewCell,
      MessageBubbleLayoutV2,
      MessageBubbleLayoutV2
    ) -> Void {
      { [weak self] cell, oldLayout, newLayout in
        self?.enqueueV2GeometryChange(in: cell, from: oldLayout, to: newLayout)
      }
    }

    private func enqueueV2GeometryChange(
      in cell: MessageCollectionViewCell,
      from oldLayout: MessageBubbleLayoutV2,
      to newLayout: MessageBubbleLayoutV2
    ) {
      guard let view = cell.messageView as? UIMessageView2, let message = cell.message else { return }
      let transition = V2GeometryTransition(
        cell: cell, view: view, layout: newLayout,
        generation: view.geometryTransitionGeneration, messageID: message.id
      )
      // Metadata-only updates need no parent layout. If this row already has
      // queued geometry, retain its latest destination even when this last
      // update has the same measured size.
      if oldLayout == newLayout, !view.hasPendingContentTransition,
         !pendingV2GeometryTransitions.contains(where: { $0.cell === cell })
      {
        transition.apply()
        transition.finish()
        return
      }
      pendingV2GeometryTransitions.removeAll { !$0.isCurrent || $0.cell === cell }
      pendingV2GeometryTransitions.append(transition)
      if pendingV2GeometryViewport == nil,
         let collectionView = currentCollectionView as? MessagesCollectionView,
         let window = collectionView.window,
         collectionView.visibleCells.contains(where: { $0 === cell })
      {
        // UIKit may resize rows as registration unwinds. Retain the presented
        // positions now, without forcing layout, so deferral does not add a jump.
        pendingV2GeometryViewport = V2GeometryViewport(
          bounds: collectionView.bounds, adjustedContentInset: collectionView.adjustedContentInset,
          window: window,
          geometry: MessageListGeometrySnapshotV2(cells: collectionView.visibleCells, window: window),
          anchor: makeV2GeometryContentAnchor(around: cell, collectionView: collectionView, window: window)
        )
      }
      scheduleV2GeometryFlush()
    }

    private func scheduleV2GeometryFlush() {
      guard !v2GeometryFlushScheduled, !pendingV2GeometryTransitions.isEmpty,
            pendingSnapshotApplies == 0 else { return }
      v2GeometryFlushScheduled = true
      // Cell registration can run inside UIKit's idle prefetch/reconfiguration.
      // Never invalidate or force parent layout on that stack. One coordinator
      // transaction consumes the latest generation for every changed row.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.v2GeometryFlushScheduled = false
        guard self.pendingSnapshotApplies == 0 else { return }
        self.flushV2GeometryChanges()
      }
    }

    private func flushV2GeometryChanges() {
      let pending = pendingV2GeometryTransitions.filter(\.isCurrent)
      let capturedViewport = pendingV2GeometryViewport
      pendingV2GeometryViewport = nil
      pendingV2GeometryTransitions.removeAll(keepingCapacity: true)
      guard let collectionView = currentCollectionView as? MessagesCollectionView,
            let window = collectionView.window else {
        for transition in pending {
          transition.apply()
          transition.finish()
        }
        return
      }
      let updates = pending.filter { transition in
        guard let cell = transition.cell, collectionView.indexPath(for: cell) != nil else {
          transition.apply()
          transition.finish()
          return false
        }
        return true
      }
      guard let changedCell = updates.first?.cell else { return }

      // Capture the model's destination before finishing at .current changes it
      // to an intermediate transform. Otherwise rapid updates retain a row offset.
      // A scroll, keyboard inset adjustment, or resize since enqueue takes
      // precedence over the old viewport. Never pull the user back to it.
      let viewport = capturedViewport.flatMap {
        $0.window === window && $0.bounds == collectionView.bounds
          && $0.adjustedContentInset == collectionView.adjustedContentInset ? $0 : nil
      }
      let geometry = viewport?.geometry
        ?? MessageListGeometrySnapshotV2(cells: collectionView.visibleCells, window: window)
      if let activeAnimator = v2GeometryAnimator {
        v2GeometryAnimator = nil
        if activeAnimator.state == .active {
          activeAnimator.stopAnimation(false)
          activeAnimator.finishAnimation(at: .current)
        }
      }

      // Finishing a superseded animator at .current preserves every participating
      // bubble. Carry its remaining destinations into the replacement animator;
      // finishing just the previous changed row here would snap it to the end.
      v2GeometryTransitions = v2GeometryTransitions.filter { transition in
        guard transition.isCurrent, let cell = transition.cell else { return false }
        guard collectionView.indexPath(for: cell) != nil else {
          transition.finish()
          return false
        }
        return !updates.contains { $0.view === transition.view }
      }
      v2GeometryTransitions.append(contentsOf: updates)
      let transitions = v2GeometryTransitions

      let anchor = viewport?.anchor ?? makeV2GeometryContentAnchor(
        around: changedCell,
        collectionView: collectionView,
        window: window
      )

      UIView.performWithoutAnimation {
        geometry.applyTargetTransforms()
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()
        restoreSendAnimationContentAnchor(anchor, in: collectionView)
        for transition in transitions where transition.isCurrent {
          transition.cell?.layoutIfNeeded()
          transition.view?.layoutIfNeeded()
        }
      }

      geometry.restorePresentedPositions(window: window)

      let animations = {
        geometry.applyTargetTransforms()
        for transition in transitions { transition.apply() }
        collectionView.layoutIfNeeded()
        for transition in transitions where transition.isCurrent {
          transition.cell?.layoutIfNeeded()
        }
      }

      guard !UIAccessibility.isReduceMotionEnabled else {
        UIView.performWithoutAnimation(animations)
        for transition in transitions { transition.finish() }
        v2GeometryTransitions.removeAll()
        return
      }

      let animator = UIViewPropertyAnimator(duration: 0.28, curve: .easeInOut)
      animator.addAnimations(animations)
      animator.addCompletion { [weak self, weak animator, weak collectionView] _ in
        guard let self, let animator, self.v2GeometryAnimator === animator else { return }
        self.v2GeometryAnimator = nil
        self.v2GeometryTransitions.removeAll()
        for transition in transitions {
          transition.finish()
          if transition.isCurrent, let cell = transition.cell {
            collectionView?.syncBubbleGradient(for: cell)
          }
        }
      }
      v2GeometryAnimator = animator
      animator.startAnimation()
    }

    private func makeV2GeometryContentAnchor(
      around changedCell: MessageCollectionViewCell,
      collectionView: MessagesCollectionView,
      window: UIWindow
    ) -> SendAnimationContentAnchor? {
      // Capture the existing viewport before installing the new row sizes.
      let changedFrame = changedCell.convert(changedCell.bounds, to: window)
      let candidates = collectionView.visibleCells.compactMap { cell -> (
        item: MessageListItem,
        frame: CGRect,
        distance: CGFloat
      )? in
        guard cell !== changedCell,
              let indexPath = collectionView.indexPath(for: cell),
              let item = dataSource.itemIdentifier(for: indexPath)
        else { return nil }
        let frame = cell.convert(cell.bounds, to: window)
        return (item, frame, abs(frame.midY - changedFrame.midY))
      }
      if let nearest = candidates.min(by: { $0.distance < $1.distance }) {
        return SendAnimationContentAnchor(
          item: nearest.item,
          frameInWindow: nearest.frame,
          contentOffset: collectionView.contentOffset
        )
      }
      guard let indexPath = collectionView.indexPath(for: changedCell),
            let item = dataSource.itemIdentifier(for: indexPath)
      else { return nil }
      return SendAnimationContentAnchor(
        item: item,
        frameInWindow: changedFrame,
        contentOffset: collectionView.contentOffset
      )
    }

    private func isFirstInGroup(at indexPath: IndexPath) -> Bool {
      guard let item = item(at: indexPath), let info = groupInfoByItem[item] else { return true }
      return info.isFirst
    }

    private func isLastInGroup(at indexPath: IndexPath) -> Bool {
      guard let item = item(at: indexPath), let info = groupInfoByItem[item] else { return true }
      return info.isLast
    }

    private func canGroup(_ earlier: FullMessage, _ later: FullMessage) -> Bool {
      guard !earlier.message.isServiceMessage, !later.message.isServiceMessage else { return false }
      guard earlier.message.fromId == later.message.fromId else { return false }
      guard groupCalendar.isDate(earlier.message.date, inSameDayAs: later.message.date) else { return false }

      let earlierID = earlier.message.messageId
      let laterID = later.message.messageId
      if earlierID > 0, laterID > 0,
         !viewModel.isCertifiedHistoryContinuation(between: earlierID, and: laterID)
      {
        return false
      }

      let gapSeconds = later.message.date.timeIntervalSince(earlier.message.date)
      return gapSeconds >= 0 && gapSeconds <= 300
    }

    private func setInitialData(animated: Bool? = false, reconfigureExisting: Bool = true) {
      let startedAt = Date()
      rebuildListSections()
      let sections = listSections
      let span = PerformanceTrace.begin(
        "IOSMessagesSnapshotBuild",
        category: .messages,
        "sections=\(sections.count) reconfigure=\(reconfigureExisting)"
      )
      var snapshot = NSDiffableDataSourceSnapshot<MessageListSectionID, MessageListItem>()

      // Add sections and their messages using dates as stable identifiers
      for section in sections {
        snapshot.appendSections([section.id])
        snapshot.appendItems(section.items, toSection: section.id)
      }

      // Reconfigure only existing items: either all shared items for data refreshes,
      // or group-boundary neighbors for structural updates that should keep layout stable.
      let currentSnapshot = dataSource.snapshot()
      let currentIds = Set(currentSnapshot.itemIdentifiers)
      let nextIds = Set(snapshot.itemIdentifiers)
      var idsToReconfigure: [MessageListItem] = []
      if reconfigureExisting {
        idsToReconfigure = Array(currentIds.intersection(nextIds))
      } else {
        let insertedItems = Array(nextIds.subtracting(currentIds))
        let deletedItems = Array(currentIds.subtracting(nextIds))

        idsToReconfigure += groupBoundaryItems(around: insertedItems, in: snapshot)
          .filter { currentIds.contains($0) && nextIds.contains($0) }
        idsToReconfigure += groupBoundaryItems(around: deletedItems, in: currentSnapshot)
          .filter { currentIds.contains($0) && nextIds.contains($0) }

        if let anchor = viewModel.threadAnchor {
          let anchorItem = MessageListItem.threadAnchor(id: anchor.id)
          if currentIds.contains(anchorItem), nextIds.contains(anchorItem) {
            idsToReconfigure.append(anchorItem)
          }
        }
      }
      idsToReconfigure = Array(Set(idsToReconfigure))
      if !idsToReconfigure.isEmpty {
        snapshot.reconfigureItems(idsToReconfigure)
      }

      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end(
        "sections=\(snapshot.sectionIdentifiers.count) items=\(snapshot.itemIdentifiers.count) duration_ms=\(durationMs)"
      )
      PerformanceTrace.slowBreadcrumb(
        "slow iOS messages snapshot build",
        category: "messages.ios",
        durationMs: durationMs,
        thresholdMs: 120,
        data: [
          "sections": snapshot.sectionIdentifiers.count,
          "items": snapshot.itemIdentifiers.count,
          "reconfigure": reconfigureExisting,
        ]
      )

      let completion = { [weak self] in
        // Kick-off the auto-hide timer on first load as well (after layout pass)
        DispatchQueue.main.async {
          self?.scheduleHideDateSeparators()
          self?.updateUnreadIfNeeded()
        }
      }

      // Cached messages are the primary first-frame content. Applying their snapshot must not
      // wait for thumbnail preparation: visible cells request high-priority thumbnails as they
      // bind, and the snapshot completion warms the visible and nearby rows concurrently.
      safeApplySnapshot(
        snapshot,
        animatingDifferences: animated ?? false,
        completion: completion
      )
    }

    private func safeApplySnapshot(
      _ snapshot: NSDiffableDataSourceSnapshot<MessageListSectionID, MessageListItem>,
      animatingDifferences: Bool,
      withCustomTiming: Bool = false,
      immediateAfterApply: (() -> Void)? = nil,
      completion: (() -> Void)? = nil
    ) {
      guard Thread.isMainThread else {
        PerformanceTrace.event(
          "IOSMessagesSnapshotApplyScheduled",
          category: .messages,
          "sections=\(snapshot.sectionIdentifiers.count) items=\(snapshot.itemIdentifiers.count)"
        )
        DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
          self?.safeApplySnapshot(
            snapshot,
            animatingDifferences: animatingDifferences,
            withCustomTiming: withCustomTiming,
            immediateAfterApply: immediateAfterApply,
            completion: completion
          )
        }
        return
      }

      let startedAt = Date()
      let sectionCount = snapshot.sectionIdentifiers.count
      let itemCount = snapshot.itemIdentifiers.count
      let span = PerformanceTrace.begin(
        "IOSMessagesSnapshotApply",
        category: .messages,
        "sections=\(sectionCount) items=\(itemCount) animated=\(animatingDifferences)"
      )

      if withCustomTiming, animatingDifferences {
        CATransaction.begin()
        CATransaction.setAnimationDuration(SendMessageAnimationTiming.duration)
        CATransaction.setAnimationTimingFunction(SendMessageAnimationTiming.verticalMediaTimingFunction)
      }

      let layout = currentCollectionView?.collectionViewLayout as? AnimatedCompositionalLayout
      let appendsOlderHistory: Bool = {
        guard !animatingDifferences else { return false }
        let previousItems = dataSource.snapshot().itemIdentifiers.filter {
          if case .message = $0 { return true }
          return false
        }
        let nextItems = snapshot.itemIdentifiers.filter {
          if case .message = $0 { return true }
          return false
        }
        return OlderHistoryPagination.appendsOlderItems(previous: previousItems, next: nextItems)
      }()
      if appendsOlderHistory {
        layout?.preserveVisibleMessageForHistoryUpdate()
      }

      pendingSnapshotApplies += 1
      dataSource.apply(snapshot, animatingDifferences: animatingDifferences) {
        if appendsOlderHistory {
          layout?.finishHistoryUpdate()
        }
        defer {
          self.pendingSnapshotApplies -= 1
          self.scheduleV2GeometryFlush()
          self.scheduleOlderHistoryCheck()
        }
        let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
        span.end(
          "sections=\(sectionCount) items=\(itemCount) animated=\(animatingDifferences) duration_ms=\(durationMs)"
        )
        PerformanceTrace.slowBreadcrumb(
          "slow iOS messages snapshot apply",
          category: "messages.ios",
          durationMs: durationMs,
          thresholdMs: 150,
          data: [
            "sections": sectionCount,
            "items": itemCount,
            "animated": animatingDifferences,
          ]
        )
        self.syncAvatarOverlay(animate: false)
        (self.currentCollectionView as? MessagesCollectionView)?.resolvePendingMessageScroll()
        self.scheduleMediaWarmupForVisibleAndNearby(reason: "snapshot")
        (self.currentCollectionView?.collectionViewLayout as? AnimatedCompositionalLayout)?
          .clearSendAnimationAppearingItemSuppression()
        completion?()
      }

      if let immediateAfterApply {
        SendMessageAnimationDiagnostics.debug(
          "snapshot immediate-post-apply sections=\(sectionCount) items=\(itemCount)"
        )
        immediateAfterApply()
      }

      if withCustomTiming, animatingDifferences {
        CATransaction.commit()
      }
    }

    private func suppressDefaultAppearingAnimationForSendTargets(
      _ items: [MessageListItem],
      in snapshot: NSDiffableDataSourceSnapshot<MessageListSectionID, MessageListItem>
    ) {
      guard let layout = currentCollectionView?.collectionViewLayout as? AnimatedCompositionalLayout else {
        return
      }

      let sendTargetItems = Set(items.filter { sendAnimationIdentity(for: $0) != nil })
      guard !sendTargetItems.isEmpty else {
        layout.clearSendAnimationAppearingItemSuppression()
        return
      }

      var suppressedIndexPaths: Set<IndexPath> = []
      for (sectionIndex, sectionId) in snapshot.sectionIdentifiers.enumerated() {
        let sectionItems = snapshot.itemIdentifiers(inSection: sectionId)
        for (itemIndex, item) in sectionItems.enumerated() where sendTargetItems.contains(item) {
          suppressedIndexPaths.insert(IndexPath(item: itemIndex, section: sectionIndex))
        }
      }

      layout.suppressSendAnimationAppearingItems(
        sendTargetItems,
        at: suppressedIndexPaths
      )
      SendMessageAnimationDiagnostics.debug(
        "layout suppress-appearing count=\(suppressedIndexPaths.count) items=\(sendTargetItems.count)"
      )
    }

    private func scheduleMediaWarmupForVisibleAndNearby(reason _: String) {
      mediaWarmupTask?.cancel()
      mediaWarmupTask = Task { @MainActor [weak self] in
        guard let self else { return }
        let previousWarmups = mediaWarmups
        mediaWarmups.removeAll()
        for warmup in previousWarmups {
          await InlineTinyThumbnailPrewarmer.cancel(warmup)
        }

        await Task.yield()
        guard !Task.isCancelled else { return }

        let groups = mediaWarmupIndexPathsAroundVisible()
        let visibleMessages = groups.visible.compactMap { self.message(at: $0) }
        let nearbyMessages = groups.nearby.compactMap { self.message(at: $0) }
        var newWarmups: [InlineTinyThumbnailWarmup] = []

        if !visibleMessages.isEmpty {
          let visibleWarmup = await ImagePrefetcher.shared.prepareThumbnails(
            for: visibleMessages,
            priority: .visible
          )
          newWarmups.append(visibleWarmup)
        }

        if !nearbyMessages.isEmpty, !Task.isCancelled {
          let nearbyWarmup = await ImagePrefetcher.shared.prepareThumbnails(
            for: nearbyMessages,
            priority: .nearby
          )
          newWarmups.append(nearbyWarmup)
        }

        guard !Task.isCancelled else {
          for warmup in newWarmups {
            await InlineTinyThumbnailPrewarmer.cancel(warmup)
          }
          return
        }
        mediaWarmups = newWarmups
      }
    }

    private func mediaWarmupIndexPathsAroundVisible() -> (visible: [IndexPath], nearby: [IndexPath]) {
      guard let collectionView = currentCollectionView else { return ([], []) }
      let visibleIndexPaths = collectionView.indexPathsForVisibleItems.sorted {
        if $0.section != $1.section { return $0.section < $1.section }
        return $0.item < $1.item
      }

      if visibleIndexPaths.isEmpty {
        guard let section = listSection(at: 0) else { return ([], []) }
        let upperBound = min(section.items.count, mediaWarmupLookaheadRows)
        return ([], (0 ..< upperBound).map { IndexPath(item: $0, section: 0) })
      }

      let visibleSet = Set(visibleIndexPaths)
      var nearbyIndexPaths = Set<IndexPath>()
      let groupedBySection = Dictionary(grouping: visibleIndexPaths, by: \.section)

      for (sectionIndex, sectionVisibleIndexPaths) in groupedBySection {
        guard let section = listSection(at: sectionIndex) else { continue }
        let visibleItems = sectionVisibleIndexPaths.map(\.item)
        guard let minVisibleItem = visibleItems.min(),
              let maxVisibleItem = visibleItems.max()
        else { continue }

        let nearbyBuffer = min(2, mediaWarmupLookaheadRows)
        let lowerBound = max(0, minVisibleItem - nearbyBuffer)
        let upperBound = min(section.items.count - 1, maxVisibleItem + mediaWarmupLookaheadRows)
        guard lowerBound <= upperBound else { continue }

        for item in lowerBound ... upperBound {
          let indexPath = IndexPath(item: item, section: sectionIndex)
          if !visibleSet.contains(indexPath) {
            nearbyIndexPaths.insert(indexPath)
          }
        }
      }

      let nearby = nearbyIndexPaths.sorted {
        if $0.section != $1.section {
          return $0.section < $1.section
        }
        return $0.item < $1.item
      }
      return (visibleIndexPaths, nearby)
    }

    private var mediaWarmupLookaheadRows: Int {
      InlineTinyThumbnailWarmupPolicy.adaptiveLookaheadRows()
    }

    private func groupBoundaryItems(
      around changedItems: [MessageListItem],
      in snapshot: NSDiffableDataSourceSnapshot<MessageListSectionID, MessageListItem>
    ) -> [MessageListItem] {
      guard !changedItems.isEmpty else { return [] }

      let changedSet = Set(changedItems)
      var boundary = Set<MessageListItem>()

      for sectionId in snapshot.sectionIdentifiers {
        let sectionItems = snapshot.itemIdentifiers(inSection: sectionId)

        for index in sectionItems.indices where changedSet.contains(sectionItems[index]) {
          if index > sectionItems.startIndex {
            boundary.insert(sectionItems[index - 1])
          }

          let nextIndex = index + 1
          if nextIndex < sectionItems.endIndex {
            boundary.insert(sectionItems[nextIndex])
          }
        }
      }

      boundary.subtract(changedSet)
      return boundary.filter { $0.messageStableId != nil }
    }

    @discardableResult
    private func reconfigureGroupBoundaryItems(
      around changedItems: [MessageListItem],
      in snapshot: inout NSDiffableDataSourceSnapshot<MessageListSectionID, MessageListItem>
    ) -> [MessageListItem] {
      let items = groupBoundaryItems(around: changedItems, in: snapshot)
        .filter { snapshot.itemIdentifiers.contains($0) }

      guard !items.isEmpty else { return [] }
      snapshot.reconfigureItems(items)
      return items
    }

    private func reconfigureVisibleItems(
      _ items: [MessageListItem],
      animateTail: Bool = true
    ) {
      guard let collectionView = currentCollectionView else { return }

      for item in Set(items) {
        guard let indexPath = dataSource.indexPath(for: item),
              let cell = collectionView.cellForItem(at: indexPath) as? MessageCollectionViewCell,
              let model = model(for: item),
              case let .message(message, displayMode) = model.content
        else {
          continue
        }

        let firstInGroup = item.isThreadAnchor ? true : groupInfoByItem[item]?.isFirst ?? true
        let lastInGroup = item.isThreadAnchor ? true : groupInfoByItem[item]?.isLast ?? true
        cell.configure(
          with: message,
          firstInGroup: firstInGroup,
          lastInGroup: lastInGroup,
          spaceId: spaceId,
          collectionWidth: collectionView.bounds.width,
          displayMode: displayMode,
          animateTail: animateTail,
          theme: theme,
          messageViewImplementation: messageViewImplementation
        )
      }
    }

    func reconfigureVisibleItemsForCurrentWidth() {
      guard let collectionView = currentCollectionView else { return }
      let visibleItems = collectionView.indexPathsForVisibleItems.compactMap {
        dataSource.itemIdentifier(for: $0)
      }
      reconfigureVisibleItems(visibleItems, animateTail: false)
    }

    func attachAvatarOverlay(over collectionView: UICollectionView, parent: UIViewController?) {
      avatarOverlayController.attach(over: collectionView, in: parent)
    }

    func detachAvatarOverlay() {
      avatarOverlayController.detach()
    }

    func syncAvatarOverlay(animate: Bool) {
      guard MessageAvatarOverlayConfig.enabled else {
        avatarOverlayController.clear()
        return
      }

      guard let collectionView = currentCollectionView else { return }
      if !avatarOverlayController.isAttached {
        let parent = (collectionView as? MessagesCollectionView)?.findViewController()
        avatarOverlayController.attach(over: collectionView, in: parent)
      }
      guard avatarOverlayController.isAttached else { return }

      guard let overlayView = avatarOverlayController.view else { return }
      let viewportFrame = avatarOverlayViewport(collectionView: collectionView, overlayView: overlayView)
      var drafts: [Int64: AvatarOverlayDraft] = [:]

      for cell in collectionView.visibleCells {
        guard let cell = cell as? MessageCollectionViewCell,
              cell.canShowAvatarOverlay,
              let userInfo = cell.avatarOverlayUserInfo,
              let indexPath = collectionView.indexPath(for: cell),
              let item = item(at: indexPath),
              let groupInfo = groupInfoByItem[item],
              let stableId = groupInfo.ownerItem.messageStableId,
              let avatarFrame = cell.avatarOverlayFrame(in: overlayView),
              let limitFrame = cell.avatarOverlayLimitFrame(in: overlayView)
        else {
          continue
        }

        let cellFrame = cell.convert(cell.bounds, to: overlayView)
        guard isValidOverlayFrame(cellFrame),
              isValidOverlayFrame(avatarFrame),
              isValidOverlayFrame(limitFrame)
        else { continue }

        if var draft = drafts[stableId] {
          draft.limitFrame = draft.limitFrame.union(limitFrame)
          if groupInfo.isLast {
            draft.frame = avatarFrame
          }
          drafts[stableId] = draft
        } else {
          drafts[stableId] = AvatarOverlayDraft(
            stableId: stableId,
            userInfo: userInfo,
            avatarX: avatarFrame.minX,
            avatarSize: avatarFrame.width,
            viewportFrame: viewportFrame,
            onTap: { [weak self] in
              self?.navigateToUser(userInfo.user.id)
            },
            frame: groupInfo.isLast ? avatarFrame : nil,
            limitFrame: limitFrame
          )
        }
      }

      let items = drafts.values.compactMap { draft -> MessageAvatarOverlayItem? in
        let frame = draft.frame ?? CGRect(
          x: draft.avatarX,
          y: draft.limitFrame.maxY - draft.avatarSize,
          width: draft.avatarSize,
          height: draft.avatarSize
        )

        guard isValidOverlayFrame(frame), isValidOverlayFrame(draft.limitFrame) else {
          return nil
        }

        return MessageAvatarOverlayItem(
          stableId: draft.stableId,
          userInfo: draft.userInfo,
          frame: frame,
          viewportFrame: draft.viewportFrame,
          limitFrame: draft.limitFrame,
          onTap: draft.onTap
        )
      }

      avatarOverlayController.sync(items: items, animate: animate)
    }

    private func avatarOverlayViewport(
      collectionView: UICollectionView,
      overlayView: UIView
    ) -> CGRect {
      let bounds = overlayView.bounds
      guard bounds.width > 0, bounds.height > 0 else { return bounds }

      let topInset = min(max(0, collectionView.contentInset.bottom), bounds.height)
      let bottomInset = min(max(0, collectionView.contentInset.top), max(0, bounds.height - topInset))
      let frame = bounds.inset(by: UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0))
      return frame.width > 0 && frame.height > 0 ? frame : bounds
    }

    private func isValidOverlayFrame(_ frame: CGRect) -> Bool {
      !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
    }

    private func navigateToUser(_ userId: Int64) {
      NotificationCenter.default.post(
        name: Notification.Name("NavigateToUser"),
        object: nil,
        userInfo: ["userId": userId]
      )
    }

    func applyUpdate(_ update: MessagesSectionedViewModel.SectionedMessagesChangeSet) {
      // Full snapshots rebuild their projection in setInitialData. Only the
      // incremental paths need it here; history pages used to do this work twice.
      switch update {
        case .messagesAdded, .messagesDeleted, .messagesUpdated:
          rebuildListSections()
        default:
          break
      }

      switch update {
        case let .reload(animated):
          setInitialData(animated: animated)

        case .sectionsChanged:
          setInitialData(animated: false, reconfigureExisting: false)

        case let .messagesAdded(sectionIndex, messageIds):
          var snapshot = dataSource.snapshot()
          let items = messageIds.map { MessageListItem.message(id: $0) }

          // Validate section index
          guard sectionIndex >= 0, sectionIndex < viewModel.sections.count else {
            setInitialData(animated: true)
            return
          }

          // Check if this is the first section (most recent)
          let shouldScroll = sectionIndex == 0
          let coordinatedCollectionView = currentCollectionView as? MessagesCollectionView
          let wasAtBottom = coordinatedCollectionView?.shouldScrollToBottom ?? false
          let sendAnimationScrollItems = Set(items.filter { sendAnimationIdentity(for: $0) != nil })
          let sendAnimationScrollIdentities = Set(sendAnimationScrollItems.compactMap(sendAnimationIdentity(for:)))
          let hasSendAnimationTargets = !sendAnimationScrollIdentities.isEmpty
          let hasDeferredSendComposeInset = coordinatedCollectionView?
            .hasDeferredSendComposeInset == true
          let shouldCoordinateSendAnimationScroll = shouldScroll && hasSendAnimationTargets && wasAtBottom
          let shouldCoordinateDeferredComposeOnly = shouldScroll &&
            !hasSendAnimationTargets &&
            hasDeferredSendComposeInset &&
            wasAtBottom
          let shouldCoordinateOutgoingInsert = shouldCoordinateSendAnimationScroll ||
            shouldCoordinateDeferredComposeOnly
          let hasIncomingItems = items.contains { item in
            guard let addedMessage = message(for: item) else { return false }
            return addedMessage.message.out != true
          }
          let shouldCoordinateIncomingInsertScroll = shouldScroll && hasIncomingItems && wasAtBottom
          let animatesDiffableInsertion = !shouldCoordinateOutgoingInsert

          // Convert section index to date
          guard let section = viewModel.section(at: sectionIndex) else {
            setInitialData(animated: true)
            return
          }
          let sectionId = MessageListSectionID.messages(dayStart: section.date)
          let anchorSectionId: MessageListSectionID?
          if snapshot.sectionIdentifiers.contains(sectionId) {
            anchorSectionId = sectionId
          } else {
            anchorSectionId = snapshot.sectionIdentifiers.first
            if sectionIndex < snapshot.sectionIdentifiers.count {
              snapshot.insertSections(
                [sectionId],
                beforeSection: snapshot.sectionIdentifiers[sectionIndex]
              )
            } else {
              snapshot.appendSections([sectionId])
            }
          }

          let sendAnimationContentAnchor: SendAnimationContentAnchor? = if shouldCoordinateOutgoingInsert,
                                                                           let collectionView =
                                                                           coordinatedCollectionView,
                                                                           let anchorSectionId
          {
            makeSendAnimationContentAnchor(
              in: snapshot,
              sectionId: anchorSectionId,
              collectionView: collectionView
            )
          } else {
            nil
          }

          if let firstItemInSection = snapshot.itemIdentifiers(inSection: sectionId).first {
            snapshot.insertItems(items, beforeItem: firstItemInSection)
          } else {
            snapshot.appendItems(items, toSection: sectionId)
          }
          let boundaryItems: [MessageListItem]
          if shouldCoordinateSendAnimationScroll {
            boundaryItems = groupBoundaryItems(around: items, in: snapshot)
              .filter { snapshot.itemIdentifiers.contains($0) }
            sendAnimationListTransaction.insert(
              items: sendAnimationScrollItems,
              identities: sendAnimationScrollIdentities
            )
            SendMessageAnimationDiagnostics.debug(
              "layout boundary-tail-local-animation count=\(boundaryItems.count)"
            )
          } else {
            boundaryItems = reconfigureGroupBoundaryItems(around: items, in: &snapshot)
          }
          reconfigureVisibleItems(
            boundaryItems,
            animateTail: true
          )
          pendingAppearingItems.formUnion(items)
          suppressDefaultAppearingAnimationForSendTargets(
            shouldCoordinateSendAnimationScroll ? Array(sendAnimationScrollItems) : [],
            in: snapshot
          )
          if shouldCoordinateSendAnimationScroll {
            SendMessageAnimationDiagnostics.event(
              "list scroll-plan-pending items=\(sendAnimationScrollItems.count) identities=\(sendAnimationScrollIdentities.count) wasAtBottomNow=\(wasAtBottom) applyAnimated=\(animatesDiffableInsertion) targetAppearingSuppressed=\(hasSendAnimationTargets)"
            )
          } else if shouldCoordinateDeferredComposeOnly {
            SendMessageAnimationDiagnostics.event(
              "list scroll-plan-pending-deferred-compose-only items=\(items.count) wasAtBottomNow=\(wasAtBottom) applyAnimated=\(animatesDiffableInsertion)"
            )
          }

          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            updateUnreadIfNeeded()
          }

          safeApplySnapshot(
            snapshot,
            animatingDifferences: animatesDiffableInsertion,
            withCustomTiming: true,
            immediateAfterApply: (shouldCoordinateOutgoingInsert || shouldCoordinateIncomingInsertScroll) ? { [
              weak self,
              weak collectionView = coordinatedCollectionView
            ] in
              guard let self, let collectionView else { return }
              if shouldCoordinateSendAnimationScroll {
                beginPendingSendAnimationTargetsAfterApply(
                  sendAnimationScrollItems,
                  identities: sendAnimationScrollIdentities,
                  collectionView: collectionView,
                  contentAnchor: sendAnimationContentAnchor
                )
              } else if shouldCoordinateDeferredComposeOnly {
                applyDeferredComposeInsetAfterFallbackInsert(
                  collectionView: collectionView,
                  contentAnchor: sendAnimationContentAnchor
                )
              } else {
                collectionView.safeScrollToTop(animated: true)
              }
            } : nil,
            completion: { [weak self] in
              if shouldScroll,
                 let collectionView = self?.currentCollectionView as? MessagesCollectionView
              {
                if !shouldCoordinateOutgoingInsert, !shouldCoordinateIncomingInsertScroll, wasAtBottom {
                  collectionView.safeScrollToTop(animated: true)
                }
              }
            }
          )
          handleIncomingMessages()

        case let .messagesDeleted(_, messageIds):
          var snapshot = dataSource.snapshot()
          let deletedItems = messageIds.flatMap { id in
            [
              MessageListItem.message(id: id),
              MessageListItem.threadAnchor(id: id),
            ]
          }.filter { snapshot.itemIdentifiers.contains($0) }
          let boundaryItems = groupBoundaryItems(around: deletedItems, in: snapshot)
          snapshot.deleteItems(deletedItems)
          let existingBoundaryItems = boundaryItems.filter { snapshot.itemIdentifiers.contains($0) }
          if !existingBoundaryItems.isEmpty {
            snapshot.reconfigureItems(existingBoundaryItems)
            reconfigureVisibleItems(existingBoundaryItems)
          }
          safeApplySnapshot(snapshot, animatingDifferences: true)

        case let .messagesUpdated(_, messageIds, animated):
          if messageViewImplementation == .v2,
             (currentCollectionView as? MessagesCollectionView)?.isContextMenuOpen == true
          {
            // UIKit animates a detached preview back to the source bubble. Reconfiguring the live
            // cell during that dismissal gives the preview and source different destination
            // geometry, producing the duplicated/ghosted bubble seen in device recordings.
            deferredContextMenuUpdatedMessageIDs.formUnion(messageIds)
            deferredContextMenuUpdateAnimated = deferredContextMenuUpdateAnimated || (animated ?? false)
          } else {
            applyUpdatedMessages(messageIds, animated: animated)
          }

        case .multiSectionUpdate:
          // Multiple sections affected - do a full data reload for simplicity
          setInitialData(animated: false, reconfigureExisting: false)
      }
    }

    private func applyUpdatedMessages(_ messageIds: [Int64], animated: Bool?) {
      var snapshot = dataSource.snapshot()
      // Safety check: only reconfigure items that actually exist in the snapshot.
      let existingItems = messageIds.flatMap { id in
        [
          MessageListItem.message(id: id),
          MessageListItem.threadAnchor(id: id),
        ]
      }.filter { snapshot.itemIdentifiers.contains($0) }
      guard !existingItems.isEmpty else { return }

      let boundaryItems = groupBoundaryItems(around: existingItems, in: snapshot)
        .filter { snapshot.itemIdentifiers.contains($0) }
      snapshot.reconfigureItems(existingItems + boundaryItems)
      reconfigureVisibleItems(boundaryItems)
      // V2 owns same-item geometry with one explicit transaction. A simultaneous diffable
      // reconfigure animation writes the same cell frames and causes bubble-height jumps.
      let animatesDiffableReconfigure = messageViewImplementation == .legacy
        && (animated ?? false)
        && !UIAccessibility.isReduceMotionEnabled
      safeApplySnapshot(snapshot, animatingDifferences: animatesDiffableReconfigure)
    }

    private func flushDeferredContextMenuMessageUpdates() {
      guard !deferredContextMenuUpdatedMessageIDs.isEmpty else { return }
      let messageIDs = deferredContextMenuUpdatedMessageIDs.sorted()
      let animated = deferredContextMenuUpdateAnimated
      deferredContextMenuUpdatedMessageIDs.removeAll(keepingCapacity: true)
      deferredContextMenuUpdateAnimated = false
      applyUpdatedMessages(messageIDs, animated: animated)
    }

    func resetVisibleReadCandidate() {
      lastVisibleReadCandidateID = nil
    }

    func updateUnreadIfNeeded() {
      guard !isPreview else { return }
      // Only mark as read when the chat is actually on-screen and app is in foreground.
      guard let collectionView = currentCollectionView,
            let window = collectionView.window,
            collectionView.isDescendant(of: window),
            !collectionView.isHidden,
            collectionView.alpha > 0.01,
            window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active
      else {
        return
      }
      // Temporary read-on-open workaround: do not wait for history coverage or
      // an advancing incoming marker. readAll clears locally before sending.
      UnreadManager.shared.readAll(peerId, chatId: chatId)
    }

    private func highestVisibleIncomingMessageID(in collectionView: UICollectionView) -> Int64? {
      let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
      guard !visibleRect.isEmpty, !visibleRect.isNull else { return nil }

      return collectionView.indexPathsForVisibleItems.compactMap { indexPath -> Int64? in
        guard let cell = collectionView.cellForItem(at: indexPath),
              !cell.isHidden,
              cell.alpha > 0.01,
              cell.frame.intersects(visibleRect),
              case .message? = item(at: indexPath),
              let message = message(at: indexPath),
              !message.message.isServiceMessage,
              message.message.messageId > 0,
              message.message.out != true
        else { return nil }
        return message.message.messageId
      }.max()
    }

    private func latestMessageId() -> Int64? {
      messages.first?.message.messageId
    }

    private func markMessagesSeen() {
      guard let latestId = latestMessageId() else { return }
      lastSeenMessageId = latestId
      if hasUnreadSinceScroll {
        hasUnreadSinceScroll = false
        notifyUnreadChanged()
      }
    }

    private func handleIncomingMessages() {
      guard let latestId = latestMessageId() else { return }
      if isAtBottomForUnread, viewModel.historyCoverage.isAtCertifiedLiveEnd {
        markMessagesSeen()
        return
      }

      if latestId > lastSeenMessageId, !hasUnreadSinceScroll {
        hasUnreadSinceScroll = true
        notifyUnreadChanged()
      }
    }

    private func notifyUnreadChanged() {
      (currentCollectionView as? MessagesCollectionView)?
        .setScrollAffordanceHasUnread(hasUnreadSinceScroll)
    }

    private func presentPhotoGallery(
      for message: FullMessage,
      sourceView: UIView,
      sourceImage: UIImage?,
      imageURL: URL
    ) {
      guard message.message.isSticker != true else { return }
      guard !isPresentingImageViewer else { return }
      guard let collectionView = currentCollectionView as? MessagesCollectionView else { return }
      guard let viewController = collectionView.findViewController() else { return }
      if viewController.presentedViewController != nil ||
        viewController.isBeingPresented ||
        viewController.isBeingDismissed
      {
        return
      }

      var items = buildImageItems()
      let stableId = message.id
      if !items.contains(where: { $0.id == stableId }) {
        items.append(ImageViewerItem(id: stableId, url: imageURL))
      }
      let initialIndex = items.firstIndex(where: { $0.id == stableId }) ?? 0

      let viewer = ImageViewerController(
        imageItems: items,
        initialIndex: initialIndex,
        sourceView: sourceView,
        sourceImage: sourceImage,
        sourceViewProvider: { [weak collectionView] id in
          collectionView?.sourceViewForMessageStableId(id)
        }
      )
      viewer.onDismiss = { [weak self] in
        self?.isPresentingImageViewer = false
      }

      isPresentingImageViewer = true
      viewController.present(viewer, animated: false)
    }

    private func buildImageItems() -> [ImageViewerItem] {
      let photoMessages = viewModel.sections
        .flatMap(\.messages)
        .filter { $0.photoInfo != nil && $0.message.isSticker != true }

      let sortedMessages = photoMessages.sorted { left, right in
        if left.message.date != right.message.date {
          return left.message.date < right.message.date
        }
        return left.message.messageId < right.message.messageId
      }

      var items: [ImageViewerItem] = []
      items.reserveCapacity(sortedMessages.count)

      for message in sortedMessages {
        guard let url = photoURL(for: message) else { continue }
        items.append(ImageViewerItem(id: message.id, url: url))
      }

      return items
    }

    private func photoURL(for message: FullMessage) -> URL? {
      guard let photoInfo = message.photoInfo,
            let photoSize = photoInfo.bestPhotoSize()
      else {
        return nil
      }

      if let localPath = photoSize.localPath {
        return FileCache.getUrl(for: .photos, localPath: localPath)
      }

      if let cdnUrl = photoSize.cdnUrl {
        return URL(string: cdnUrl)
      }

      return nil
    }

    private var sizeCache: [MessageListItem: CGSize] = [:]
    private let maxCacheSize = 1_000

    func createReactionPickerView(for fullMessage: FullMessage) -> UIView {
      let preferredSkinTone = EmojiSkinTonePreferenceStore.current()
      var seenReactions = Set<String>()
      let reactions = ReactionPickerEmojiUsageStore.suggestedEmojis().compactMap { emoji -> String? in
        let preferredEmoji = preferredSkinTone.applying(to: emoji)
        return seenReactions.insert(preferredEmoji).inserted ? preferredEmoji : nil
      }

      let containerWidth = currentCollectionView?.window?.bounds.width
        ?? currentCollectionView?.bounds.width
        ?? UIScreen.main.bounds.width
      let preferredWidth = ContextMenuAccessoryLayout.reactionPickerWidth(for: containerWidth)

      let containerView = UIView()
      containerView.translatesAutoresizingMaskIntoConstraints = false
      containerView.backgroundColor = .clear

      let containerHeight: CGFloat
      let horizontalGlassInset: CGFloat
      let verticalGlassInset: CGFloat
      if #available(iOS 26.0, *) {
        containerHeight = ContextMenuAccessoryLayout.accessoryHostHeight
        horizontalGlassInset = 0
        verticalGlassInset = (ContextMenuAccessoryLayout.accessoryHostHeight - ContextMenuAccessoryLayout
          .reactionPickerHeight) / 2
      } else {
        containerHeight = ContextMenuAccessoryLayout.reactionPickerHeight
        horizontalGlassInset = 0
        verticalGlassInset = 0
      }

      let effectView: UIVisualEffectView
      if #available(iOS 26.0, *) {
        let glassEffect = UIGlassEffect(style: .regular)
        glassEffect.isInteractive = true
        effectView = UIVisualEffectView(effect: glassEffect)
      } else {
        effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
      }
      effectView.translatesAutoresizingMaskIntoConstraints = false
      effectView.layer.cornerRadius = ContextMenuAccessoryLayout.reactionPickerHeight / 2
      effectView.layer.cornerCurve = .continuous
      effectView.clipsToBounds = true
      containerView.addSubview(effectView)

      let scrollView = UIScrollView()
      scrollView.translatesAutoresizingMaskIntoConstraints = false
      scrollView.showsHorizontalScrollIndicator = false
      scrollView.alwaysBounceHorizontal = true
      effectView.contentView.addSubview(scrollView)

      let stackView = UIStackView()
      stackView.axis = .horizontal
      stackView.alignment = .center
      stackView.spacing = 6
      stackView.translatesAutoresizingMaskIntoConstraints = false
      scrollView.addSubview(stackView)

      for reaction in reactions {
        let button = createReactionButton(
          reaction: reaction,
          messageStableId: fullMessage.id,
          messageId: fullMessage.message.messageId,
          chatId: fullMessage.message.chatId,
          randomId: fullMessage.message.randomId
        )
        stackView.addArrangedSubview(button)
      }

      NSLayoutConstraint.activate([
        containerView.widthAnchor.constraint(equalToConstant: preferredWidth),
        containerView.heightAnchor.constraint(equalToConstant: containerHeight),

        effectView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: verticalGlassInset),
        effectView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: horizontalGlassInset),
        effectView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -horizontalGlassInset),
        effectView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -verticalGlassInset),

        scrollView.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
        scrollView.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor),
        scrollView.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),

        stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 7),
        stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 4),
        stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -4),
        stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -7),
        stackView.heightAnchor.constraint(equalToConstant: 38),
      ])

      containerView.clipsToBounds = false

      return containerView
    }

    private func createReactionButton(
      reaction: String,
      messageStableId: Int64,
      messageId: Int64,
      chatId: Int64,
      randomId: Int64?
    ) -> UIButton {
      let button = UIButton(type: .system)
      button.translatesAutoresizingMaskIntoConstraints = false

      var configuration = UIButton.Configuration.plain()
      configuration.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)

      configuration.title = reaction
      configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var outgoing = incoming
        outgoing.font = .systemFont(ofSize: 22)
        return outgoing
      }

      button.configuration = configuration

      button.accessibilityLabel = reaction

      button.layer.cornerRadius = 19
      button.clipsToBounds = true
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 38),
        button.heightAnchor.constraint(equalToConstant: 38),
      ])

      button.addAction(UIAction { [weak self, weak button] _ in
        guard let self, let button else { return }
        handleReactionButtonTap(
          button,
          reaction: reaction,
          messageStableId: messageStableId,
          messageId: messageId,
          chatId: chatId,
          randomId: randomId
        )
      }, for: .touchUpInside)
      button.addTarget(self, action: #selector(buttonTouchDown(_:)), for: .touchDown)
      button.addTarget(
        self,
        action: #selector(buttonTouchUp(_:)),
        for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
      )

      return button
    }

    @objc private func buttonTouchDown(_ sender: UIButton) {
      let generator = UIImpactFeedbackGenerator(style: .light)
      generator.prepare()
      generator.impactOccurred()

      let updates = {
        sender.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        sender.backgroundColor = self.theme.primary.uiColor.withAlphaComponent(0.3)
      }
      guard !UIAccessibility.isReduceMotionEnabled else {
        UIView.performWithoutAnimation(updates)
        return
      }
      UIView.animate(withDuration: 0.1, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
        updates()
      }
    }

    @objc private func buttonTouchUp(_ sender: UIButton) {
      let updates = {
        sender.transform = .identity
        sender.backgroundColor = .clear
      }
      guard !UIAccessibility.isReduceMotionEnabled else {
        UIView.performWithoutAnimation(updates)
        return
      }
      UIView.animate(
        withDuration: 0.16,
        delay: 0,
        usingSpringWithDamping: 0.82,
        initialSpringVelocity: 0.4,
        options: [.allowUserInteraction, .beginFromCurrentState],
        animations: updates
      )
    }

    private func handleReactionButtonTap(
      _ sender: UIButton,
      reaction emoji: String,
      messageStableId: Int64,
      messageId: Int64,
      chatId: Int64,
      randomId: Int64?
    ) {
      buttonTouchUp(sender)
      dismissContextMenuIfNeeded()
      guard let fullMessage = currentFullMessage(
        stableId: messageStableId,
        messageId: messageId,
        chatId: chatId,
        randomId: randomId
      ) else { return }
      let message = fullMessage.message

      if fullMessage.reactions
        .filter({ $0.reaction.emoji == emoji && $0.reaction.userId == Auth.shared.getCurrentUserId() ?? 0 })
        .first != nil
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
        ReactionPickerEmojiUsageStore.recordPick(emoji)
      }
    }

    private func currentFullMessage(
      stableId: Int64,
      messageId: Int64,
      chatId: Int64,
      randomId: Int64?
    ) -> FullMessage? {
      for section in viewModel.sections {
        if let message = section.messages.first(where: {
          $0.id == stableId ||
            ($0.message.messageId == messageId && $0.message.chatId == chatId) ||
            (randomId != nil && $0.message.randomId == randomId && $0.message.chatId == chatId)
        }) {
          return message
        }
      }
      return nil
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
      guard let item = item(at: indexPath) else { return .zero }

      if case .unreadSeparator = item {
        return CGSize(width: collectionView.bounds.width, height: 34)
      }
      if case .collapsedHistory = item {
        return CGSize(width: collectionView.bounds.width, height: 34)
      }

      if let cachedSize = sizeCache[item] {
        return cachedSize
      }

      guard let message = message(for: item) else { return .zero }

      let availableWidth = collectionView.bounds.width - 16
      let textWidth = availableWidth - 32

      if message.message.isServiceMessage {
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let text = message.serviceDisplayText ?? message.message.serviceFallbackText ?? message.message.text ?? ""
        let textHeight = (text as NSString).boundingRect(
          with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin, .usesFontLeading],
          attributes: [.font: font],
          context: nil
        ).height
        let size = CGSize(width: availableWidth, height: max(34, ceil(textHeight) + 18))
        if sizeCache.count >= maxCacheSize {
          let keysToRemove = Array(sizeCache.keys.prefix(sizeCache.count / 2))
          for key in keysToRemove {
            sizeCache.removeValue(forKey: key)
          }
        }
        sizeCache[item] = size
        return size
      }

      let font = UIFont.preferredFont(forTextStyle: .body)
      let text = message.message.text ?? ""

      let textHeight = (text as NSString).boundingRect(
        with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font],
        context: nil
      ).height

      let size = CGSize(width: availableWidth, height: ceil(textHeight) + 24)

      if sizeCache.count >= maxCacheSize {
        // Instead of clearing all, remove oldest entries
        let keysToRemove = Array(sizeCache.keys.prefix(sizeCache.count / 2))
        for key in keysToRemove {
          sizeCache.removeValue(forKey: key)
        }
      }
      sizeCache[item] = size

      return size
    }

    func clearSizeCache() {
      sizeCache.removeAll(keepingCapacity: true)
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      minimumLineSpacingForSectionAt section: Int
    ) -> CGFloat {
      0
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      insetForSectionAt section: Int
    ) -> UIEdgeInsets {
      .zero
    }

    func collectionView(
      _ collectionView: UICollectionView,
      layout collectionViewLayout: UICollectionViewLayout,
      minimumInteritemSpacingForSectionAt section: Int
    ) -> CGFloat {
      0
    }

    func collectionView(
      _ collectionView: UICollectionView,
      contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
      point: CGPoint
    ) -> UIContextMenuConfiguration? {
      guard let indexPath = indexPaths.first,
            let item = item(at: indexPath),
            !item.isThreadAnchor,
            let fullMessage = message(for: item) else { return nil }
      let message = fullMessage.message
      guard let cell = currentCollectionView?.cellForItem(at: indexPath) as? MessageCollectionViewCell else {
        return nil
      }

      let mathSource = (cell.messageView as? UIMessageView2).flatMap { view in
        view.mathSource(atPointInMessageView: collectionView.convert(point, to: view))
      }

      // Check if the touch point is within a view that has its own context menu interaction
      if let messageView = cell.messageView {
        let pointInMessageView = collectionView.convert(point, to: messageView)

        // Let link long-press in the message text handle its own menu.
        if messageView.linkURL(atPointInMessageView: pointInMessageView) != nil {
          return nil
        }

        // Check if the point is within any subview that has a context menu interaction
        if let hitView = messageView.hitTest(pointInMessageView, with: nil) {
          // Check if the hit view or any of its superviews (up to messageView) has a context menu interaction
          var currentView: UIView? = hitView
          while let view = currentView, view != messageView {
            if view.interactions.contains(where: { $0 is UIContextMenuInteraction }) {
              // Allow the inner view's context menu to handle this
              return nil
            }
            currentView = view.superview
          }
        }
      }

      if message.isServiceMessage {
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
          guard let self else { return UIMenu(children: []) }
          let replyAction = UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
            ChatState.shared.setReplyingMessageId(peer: message.peerId, id: message.messageId)
          }
          let deleteAction = UIAction(
            title: "Delete",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
          ) { _ in
            self.showDeleteConfirmation(
              messageId: message.messageId,
              peerId: message.peerId,
              chatId: message.chatId
            )
          }
          return UIMenu(children: [replyAction, deleteAction])
        }
      }

      let reactionPickerView = createReactionPickerView(for: fullMessage)

      let isOutgoing = message.out == true
      let alignment: ContextMenuAccessoryAlignment = isOutgoing ? .trailing : .leading

      let configuration = ContextMenuAccessoryConfiguration(
        location: .below,
        trackingAxis: .vertical,
        attachment: .center,
        alignment: alignment,
        attachmentOffset: -16,
        alignmentOffset: 0,
        gravity: 0
      )

      let identifierView = ContextMenuIdentifierUIView(
        accessoryView: reactionPickerView,
        configuration: configuration
      )

      collectionView.addSubview(identifierView)

      return UIContextMenuConfiguration(identifier: identifierView, previewProvider: nil) { [weak self] _ in
        guard let self else { return UIMenu(children: []) }

        let isMessageSending = message.status == .sending
        let isMessageFailed = message.status == .failed

        var actions: [UIAction] = []

        if message.hasText {
          let copyAction = UIAction(title: "Copy", image: UIImage(systemName: "square.on.square")) { _ in
            UIPasteboard.general.string = message.text
          }
          actions.append(copyAction)
        }

        if let mathSource {
          actions.append(UIAction(title: "Copy LaTeX", image: UIImage(systemName: "function")) { _ in
            UIPasteboard.general.string = mathSource
          })
        }

        if isMessageSending {
          if fullMessage.photoInfo != nil {
            let copyPhotoAction = UIAction(title: "Copy Photo", image: UIImage(systemName: "doc.on.clipboard")) {
              [weak self] _ in
              guard let self else { return }
              if let image = cell.messageView?.newPhotoView.getCurrentImage() {
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

          let cancelAction = UIAction(title: "Cancel", attributes: .destructive) { _ in
            if let transactionId = message.transactionId, !transactionId.isEmpty {
              Log.shared.debug("Canceling message with transaction ID: \(transactionId)")

              Transactions.shared.cancel(transactionId: transactionId)
              Task {
                let _ = try? await AppDatabase.shared.dbWriter.write { db in
                  try Message.deleteMessages(db, messageIds: [message.messageId], chatId: message.chatId)
                }

                MessagesPublisher.shared
                  .messagesDeleted(messageIds: [message.messageId], peer: message.peerId)
              }
            } else {
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
          actions.append(cancelAction)

          return UIMenu(children: actions)
        }

        if isMessageFailed {
          if fullMessage.photoInfo != nil {
            let copyPhotoAction = UIAction(title: "Copy Photo", image: UIImage(systemName: "doc.on.clipboard")) {
              [weak self] _ in
              guard let self else { return }
              if let image = cell.messageView?.newPhotoView.getCurrentImage() {
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

          let resendAction = UIAction(title: "Resend", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            self?.resendMessage(fullMessage)
          }
          actions.append(resendAction)

          let deleteAction = UIAction(title: "Delete", attributes: .destructive) { [weak self] _ in
            self?.showDeleteConfirmationForFailed(
              messageId: message.messageId,
              peerId: message.peerId,
              chatId: message.chatId
            )
          }
          actions.append(deleteAction)

          return UIMenu(children: actions)
        }

        if fullMessage.photoInfo != nil {
          let copyPhotoAction = UIAction(title: "Copy Photo", image: UIImage(systemName: "doc.on.clipboard")) {
            [weak self] _ in
            guard let self else { return }
            if let image = cell.messageView?.newPhotoView.getCurrentImage() {
              UIPasteboard.general.image = image
              ToastManager.shared.showToast(
                "Photo copied to clipboard",
                type: .success,
                systemImage: "doc.on.clipboard"
              )
            }
          }
          actions.append(copyPhotoAction)

          let savePhotoAction = UIAction(
            title: "Save Photo",
            image: UIImage(systemName: "square.and.arrow.down")
          ) { [weak self] _ in
            guard let self else { return }
            if let image = cell.messageView?.newPhotoView.getCurrentImage() {
              UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
              ToastManager.shared.showToast(
                "Photo saved to Photos Library",
                type: .success,
                systemImage: "photo"
              )
            } else {
              ToastManager.shared.showToast(
                "Failed to save photo",
                type: .error,
                systemImage: "exclamationmark.triangle"
              )
            }
          }
          actions.append(savePhotoAction)
        }

        let replyAction = UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
          ChatState.shared.setReplyingMessageId(peer: message.peerId, id: message.messageId)
        }
        actions.append(replyAction)

        let replyThreadAction = UIAction(
          title: message.isSubthreadPlacement ? "Open Subthread" : "Reply in Thread",
          image: UIImage(systemName: "arrowshape.turn.up.left.circle")
        ) { _ in
          ReplyThreadNavigator.open(message: message, source: .menu)
        }
        actions.append(replyThreadAction)

        if !message.isSubthreadPlacement {
          let forwardAction = UIAction(title: "Forward", image: UIImage(systemName: "arrowshape.turn.up.right")) {
            [weak self] _ in
            guard let self else { return }
            presentForwardSheet(fullMessage)
          }
          actions.append(forwardAction)
        }

        if let acknowledgementAction = fullMessage.acknowledgementAction(
          currentUserId: Auth.shared.getCurrentUserId()
        ) {
          actions.append(UIAction(
            title: acknowledgementAction.clear ? "Remove Ack" : "Ack",
            image: UIImage(systemName: acknowledgementAction.clear ? "xmark" : "checkmark")
          ) { _ in
            Task {
              do {
                try await Api.realtime.send(.acknowledgeMessages(
                  message: fullMessage,
                  action: acknowledgementAction
                ))
              } catch {
                Log.scoped("Acknowledgement").error("Failed to update Ack", error: error)
                ToastManager.shared.showToast(
                  "Could not update Ack",
                  type: .error,
                  systemImage: "exclamationmark.triangle.fill"
                )
              }
            }
          })
        }

        let pinned = isMessagePinned(message)
        let pinAction = UIAction(
          title: pinned ? "Unpin" : "Pin",
          image: UIImage(systemName: pinned ? "pin.slash" : "pin")
        ) { [weak self] _ in
          self?.togglePinMessage(message, unpin: pinned)
        }

        var editAction: UIAction?
        if message.fromId == Auth.shared.getCurrentUserId() ?? 0, message.hasText {
          editAction = UIAction(title: "Edit", image: UIImage(systemName: "bubble.and.pencil")) { _ in
            ChatState.shared.setEditingMessageId(peer: message.peerId, id: message.messageId)
          }
        }

        let willDoAction = createWillDoMenu(for: message)
        let linearIssueAction = createLinearIssueMenu(for: message)

        let deleteAction = UIAction(
          title: "Delete",
          image: UIImage(systemName: "trash"),
          attributes: .destructive
        ) { _ in
          self.showDeleteConfirmation(
            messageId: message.messageId,
            peerId: message.peerId,
            chatId: message.chatId
          )
        }

        var menuChildren: [UIMenuElement] = []

        var basicActions = actions
        if let editAction {
          basicActions.append(editAction)
        }
        basicActions.append(pinAction)

        if !basicActions.isEmpty {
          let basicMenu = UIMenu(title: "", options: .displayInline, children: basicActions)
          menuChildren.append(basicMenu)
        }

        let integrationActions = [willDoAction, linearIssueAction].compactMap(\.self)
        if !integrationActions.isEmpty {
          let integrationsMenu = UIMenu(
            title: "Actions",
            image: UIImage(systemName: "ellipsis.circle"),
            children: integrationActions
          )
          menuChildren.append(integrationsMenu)
        }

        let deleteMenu = UIMenu(title: "", options: .displayInline, children: [deleteAction])
        menuChildren.append(deleteMenu)

        if let attribution = fullMessage.acknowledgementAttributionLabel {
          let attributionAction = UIAction(
            title: attribution,
            image: UIImage(systemName: "person.2"),
            attributes: .disabled
          ) { _ in }
          menuChildren.append(UIMenu(
            title: "",
            options: .displayInline,
            children: [attributionAction]
          ))
        }

        return UIMenu(children: menuChildren)
      }
    }

    func showDeleteConfirmation(messageId: Int64, peerId: Peer, chatId: Int64) {
      // TODO: we have duplicate code here 2 findViewController func
      func findViewController(from view: UIView?) -> UIViewController? {
        guard let view else { return nil }

        var responder: UIResponder? = view
        while let nextResponder = responder?.next {
          if let viewController = nextResponder as? UIViewController {
            return viewController
          }
          responder = nextResponder
        }
        return nil
      }

      guard let viewController = findViewController(from: currentCollectionView) else { return }

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
                messageIds: [messageId],
                peerId: peerId,
                chatId: chatId
              )
            )
          )
        }
      })

      viewController.present(alert, animated: true)
    }

    func presentForwardSheet(_ fullMessage: FullMessage) {
      func findViewController(from view: UIView?) -> UIViewController? {
        guard let view else { return nil }

        var responder: UIResponder? = view
        while let nextResponder = responder?.next {
          if let viewController = nextResponder as? UIViewController {
            return viewController
          }
          responder = nextResponder
        }
        return nil
      }

      guard let viewController = findViewController(from: currentCollectionView) else { return }

      let rootView = InlineUI.ForwardMessagesSheet(
        messages: [fullMessage],
        onSelect: { destination, selection in
          let destinationPeer = destination.peerId
          ChatState.shared.setForwardingMessages(
            peer: destinationPeer,
            fromPeerId: selection.fromPeerId,
            sourceChatId: selection.sourceChatId,
            messageIds: selection.messageIds
          )

          var userInfo: [AnyHashable: Any] = [:]
          if let userId = destinationPeer.asUserId() {
            userInfo["peerUserId"] = userId
          }
          if let threadId = destinationPeer.asThreadId() {
            userInfo["peerThreadId"] = threadId
          }
          NotificationCenter.default.post(
            name: Notification.Name("NavigateToForwardDestination"),
            object: nil,
            userInfo: userInfo
          )
        },
        onSend: { destinations, selection in
          await self.forwardMessages(
            destinations: destinations,
            selection: selection
          )
        }
      )
      .appDatabase(AppDatabase.shared)

      let hostingController = UIHostingController(rootView: rootView)
      hostingController.modalPresentationStyle = UIModalPresentationStyle.pageSheet

      viewController.present(hostingController, animated: true)
    }

    @MainActor
    private func forwardMessages(
      destinations: [HomeChatItem],
      selection: InlineUI.ForwardMessagesSheet.ForwardMessagesSelection
    ) async {
      guard !destinations.isEmpty else { return }
      guard !selection.messageIds.isEmpty else {
        Log.shared.error("Forward failed: empty message ids")
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
          Log.shared.error("Forward failed", error: error)
        }
      }

      ToastManager.shared.showToast(
        "Forwarded to \(destinations.count) chats",
        type: .success,
        systemImage: "arrowshape.turn.up.right"
      )
    }

    func showDeleteConfirmationForFailed(messageId: Int64, peerId: Peer, chatId: Int64) {
      func findViewController(from view: UIView?) -> UIViewController? {
        guard let view else { return nil }

        var responder: UIResponder? = view
        while let nextResponder = responder?.next {
          if let viewController = nextResponder as? UIViewController {
            return viewController
          }
          responder = nextResponder
        }
        return nil
      }

      guard let viewController = findViewController(from: currentCollectionView) else { return }

      let alert = UIAlertController(
        title: "Delete Failed Message",
        message: "Are you sure you want to delete this failed message?",
        preferredStyle: .alert
      )

      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

      alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
        guard let self else { return }
        Task {
          // Delete locally without server call since it failed to send
          let _ = try? await AppDatabase.shared.dbWriter.write { db in
            try Message.deleteMessages(db, messageIds: [messageId], chatId: chatId)
          }

          await MainActor.run {
            MessagesPublisher.shared
              .messagesDeleted(messageIds: [messageId], peer: peerId)
          }
        }
      })

      viewController.present(alert, animated: true)
    }

    func resendMessage(_ fullMessage: FullMessage) {
      let message = fullMessage.message

      Task {
        // Reconstruct media items from the failed message
        var mediaItems: [FileMediaItem] = []

        // Handle photo
        if let photoInfo = fullMessage.photoInfo {
          let mediaItem = FileMediaItem.photo(photoInfo)
          mediaItems.append(mediaItem)
        }

        // Handle video
        if let videoInfo = fullMessage.videoInfo {
          let mediaItem = FileMediaItem.video(videoInfo)
          mediaItems.append(mediaItem)
        }

        // Handle document
        if let documentInfo = fullMessage.documentInfo {
          let mediaItem = FileMediaItem.document(documentInfo)
          mediaItems.append(mediaItem)
        }

        // Delete the failed message first
        _ = try? await AppDatabase.shared.dbWriter.write { db in
          try Message.deleteMessages(db, messageIds: [message.messageId], chatId: message.chatId)
        }

        await MainActor.run {
          MessagesPublisher.shared
            .messagesDeleted(messageIds: [message.messageId], peer: message.peerId)
        }

        // Send new message with reconstructed data
        if mediaItems.isEmpty {
          // Text-only message
          try await Api.realtime.send(
            .sendMessage(
              text: message.text ?? "",
              peerId: message.peerId,
              chatId: message.chatId,
              replyToMsgId: message.repliedToMessageId, // Preserve original reply
              isSticker: message.isSticker,
              entities: message.entities
            )
          )
        } else {
          // Message with media
          await Transactions.shared.mutate(
            transaction: .sendMessage(.init(
              text: message.text,
              peerId: message.peerId,
              chatId: message.chatId,
              mediaItems: mediaItems,
              replyToMsgId: message.repliedToMessageId, // Preserve original reply
              isSticker: message.isSticker,
              entities: message.entities
            ))
          )
        }
      }
    }

    // MARK: - UICollectionView

    func collectionView(
      _ collectionView: UICollectionView,
      contextMenuConfiguration configuration: UIContextMenuConfiguration,
      highlightPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
      targetedPreview(for: indexPath)
    }

    func collectionView(
      _ collectionView: UICollectionView,
      contextMenuConfiguration configuration: UIContextMenuConfiguration,
      dismissalPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
      targetedPreview(for: indexPath)
    }

    // MARK: - Private

    private func targetedPreview(for indexPath: IndexPath) -> UITargetedPreview? {
      guard let collectionView = currentCollectionView,
            let cell = collectionView.cellForItem(at: indexPath) as? MessageCollectionViewCell,
            let messageView = cell.messageView else { return nil }

      let parameters = UIPreviewParameters()
      parameters.backgroundColor = .clear

      if messageView.fullMessage.message.isServiceMessage {
        let serviceView = messageView.serviceContainerView
        parameters.visiblePath = UIBezierPath(
          roundedRect: serviceView.bounds,
          cornerRadius: serviceView.layer.cornerRadius
        )
        return UITargetedPreview(view: serviceView, parameters: parameters)
      }

      let bubbleView = messageView.bubbleView
      parameters.visiblePath = bubbleView.visiblePath()

      return UITargetedPreview(view: bubbleView, parameters: parameters)
    }

    private var isUserDragging = false
    private var isUserScrollInEffect = false
    private var isAtBottomForUnread = true
    private var lastSeenMessageId: Int64 = 0
    private var hasUnreadSinceScroll = false

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      olderHistoryPagination.beginGesture()
      isUserDragging = true
      isUserScrollInEffect = true
      // Show date badge immediately when user starts interacting
      dateSeparatorHideWorkItem?.cancel()
      setDateSeparators(hidden: false, animated: true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      isUserDragging = false
      if !decelerate {
        isUserScrollInEffect = false
        scheduleOlderHistoryCheck()
        scheduleHideDateSeparators()
        scheduleMediaWarmupForVisibleAndNearby(reason: "scroll_drag_end")
        updateUnreadIfNeeded()
      }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
      isUserScrollInEffect = false
      scheduleOlderHistoryCheck()
      scheduleHideDateSeparators()
      scheduleMediaWarmupForVisibleAndNearby(reason: "scroll_deceleration_end")
      updateUnreadIfNeeded()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
      scheduleHideDateSeparators()
      scheduleMediaWarmupForVisibleAndNearby(reason: "scroll_animation_end")
      updateUnreadIfNeeded()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      let isUserInteractingWithScrollView = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating

      // Keep the date badge visible only for user-driven scrolling, not programmatic offset/inset updates.
      if isUserInteractingWithScrollView {
        dateSeparatorHideWorkItem?.cancel()
        setDateSeparators(hidden: false, animated: false)
      }

      // Reminder: textViewVerticalMargin in ComposeView affects scrollView.contentOffset.y number
      // (textViewVerticalMargin = 7.0  -> contentOffset.y = -64.0 | textViewVerticalMargin = 4.0 -> contentOffset.y =
      // -58.0)

      guard let messagesCollectionView = currentCollectionView as? MessagesCollectionView else { return }

      messagesCollectionView.reconcileScrollAffordance()
      let isAtBottom = messagesCollectionView.isAtVisualBottomForUnread
      isAtBottomForUnread = isAtBottom
      viewModel.setAtBottom(isAtBottom)

      if isAtBottom, viewModel.historyCoverage.isAtCertifiedLiveEnd {
        markMessagesSeen()
      }

      if isUserScrollInEffect {
        if isNearOldestHistoryEdge(scrollView) {
          olderHistoryPagination.requestOlder()
        }
        loadOlderMessagesIfNeeded()
        let threshold: CGFloat = 100
        if scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + threshold {
          loadNewerMessagesIfNeeded()
        }
      }

      syncAvatarOverlay(animate: false)
    }

    private func loadNewerMessagesIfNeeded() {
      guard newerLoadTask == nil, let newestID = viewModel.newestLoadedMessageId else { return }
      guard viewModel.canLoadNewerFromLocal || viewModel.needsNewerHistoryRepair else { return }
      let needsRemote = viewModel.needsNewerHistoryRepair
      if needsRemote,
         let attempt = lastNewerAttempt, attempt.messageID == newestID,
         Date().timeIntervalSince(attempt.date) < 2 { return }
      if needsRemote { lastNewerAttempt = (newestID, Date()) }
      let peer = peerId
      newerLoadTask = Task { @MainActor [weak self] in
        defer { self?.newerLoadTask = nil }
        do {
          if needsRemote {
            let outcome = try await MessageHistoryRepairCoordinator.shared.loadNewer(peer: peer, afterID: newestID)
            guard outcome == .loaded else { return }
          }
          guard let self, !Task.isCancelled else { return }
          _ = await viewModel.loadBatchAsync(at: .newer, allowUnavailableLocal: true)
        } catch is CancellationError {
          return
        } catch {
          Log.shared.error("Failed to load newer history", error: error)
        }
      }
    }

    private func loadOlderMessagesIfNeeded() {
      guard !isPreview, pendingSnapshotApplies == 0,
            let collectionView = currentCollectionView, collectionView.window != nil,
            let request = olderHistoryPagination.beginRequest(
              oldestMessageID: viewModel.oldestLoadedMessageId ?? messages.last?.message.messageId,
              isNearEdge: isNearOldestHistoryEdge(collectionView)
            )
      else { return }

      // One task owns both cache paging and remote repair. A scroll during either
      // operation retains demand instead of canceling or overlapping requests.
      #if DEBUG || DEBUG_BUILD
      Log.shared.debug("history-pagination start local=\(viewModel.canLoadOlderFromLocal)")
      #endif
      olderLoadTask = Task { @MainActor [weak self] in
        guard let self else { return }
        var succeeded = false
        defer {
          if self.olderHistoryPagination.finishRequest(
            request, oldestMessageID: self.viewModel.oldestLoadedMessageId, succeeded: succeeded
          ) {
            self.olderLoadTask = nil
            #if DEBUG || DEBUG_BUILD
            Log.shared.debug(
              "history-pagination finish succeeded=\(succeeded) demand=\(self.olderHistoryPagination.hasDemand)"
            )
            #endif
            self.scheduleOlderHistoryCheck()
          }
        }

        do {
          try Task.checkCancellation()
          if viewModel.canLoadOlderFromLocal {
            _ = await viewModel.loadBatchAsync(at: .older)
            try Task.checkCancellation()
            if let oldestID = viewModel.oldestLoadedMessageId, oldestID < request.beforeMessageID {
              succeeded = true
              return
            }
            // A local read that failed must not become an automatic network retry loop.
            guard !viewModel.canLoadOlderFromLocal else { return }
          }

          let outcome = try await MessageHistoryRepairCoordinator.shared.loadOlder(
            peer: peerId, beforeID: request.beforeMessageID
          )
          try Task.checkCancellation()
          if outcome == .empty {
            succeeded = true
            return
          }
          // Even .notNeeded can mean another request already populated the local cache.
          _ = await viewModel.loadBatchAsync(at: .older, allowUnavailableLocal: true)
          try Task.checkCancellation()
          succeeded = true
        } catch is CancellationError {
          return
        } catch {
          Log.shared.error("Failed to load older messages from remote", error: error)
        }
      }
    }

    private func isNearOldestHistoryEdge(_ scrollView: UIScrollView) -> Bool {
      OlderHistoryPagination.isNearOldestEdge(
        offsetY: scrollView.contentOffset.y,
        contentHeight: scrollView.contentSize.height,
        viewportHeight: scrollView.bounds.height,
        topInset: scrollView.adjustedContentInset.top,
        bottomInset: scrollView.adjustedContentInset.bottom
      )
    }

    private func scheduleOlderHistoryCheck() {
      guard olderHistoryPagination.hasDemand, !olderHistoryCheckScheduled else { return }
      olderHistoryCheckScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.olderHistoryCheckScheduled = false
        guard self.olderHistoryPagination.hasDemand, self.pendingSnapshotApplies == 0 else { return }
        // A page can finish after the gesture or before its snapshot finishes.
        // Recheck the final geometry from both completions, never from a stale content size.
        self.currentCollectionView?.layoutIfNeeded()
        self.loadOlderMessagesIfNeeded()
      }
    }

    func scheduleUpdateItems() {
      updateItemsSafely()
    }

    private func updateItemsSafely() {
      let currentSnapshot = dataSource.snapshot()
      let currentIds = Set(currentSnapshot.itemIdentifiers)
      let availableIds = Set(items)
      let missingIds = availableIds.subtracting(currentIds)

      if !missingIds.isEmpty {
        setInitialData(animated: false)
      }
    }

    // MARK: - Date Separator Visibility

    private func setDateSeparators(hidden: Bool, animated: Bool) {
      guard let collectionView = currentCollectionView else { return }

      let footers = collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter)

      // The physical bottom edge of the visible rect in the collection-view's coordinate space
      let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.contentInset
        .bottom

      for view in footers {
        guard let separator = view as? DateSeparatorView else { continue }

        // Detect if this footer is currently pinned to the bottom (sticky)
        let isPinned = abs(separator.frame.maxY - visibleBottom) < 1.0
        guard isPinned else { continue }

        separator.setVisible(!hidden, animated: animated)
      }
    }

    private func dateSeparatorInteractionChanged(_ isInteracting: Bool) {
      if isInteracting,
         let collectionView = currentCollectionView,
         !collectionView.isDragging,
         collectionView.isDecelerating || collectionView.isScrollAnimating
      {
        // A date press should stop existing motion and still reach the button on this tap.
        #if DEBUG || DEBUG_BUILD
        Log.shared.debug(
          "date-navigation event=stop-scroll decelerating=\(collectionView.isDecelerating) animating=\(collectionView.isScrollAnimating)"
        )
        #endif
        isUserScrollInEffect = false
        collectionView.stopScrollingAndZooming()
      }

      // Stopping motion can schedule a hide through scroll delegate callbacks.
      dateSeparatorHideWorkItem?.cancel()
      if isInteracting {
        setDateSeparators(hidden: false, animated: false)
      } else if !isUserDragging {
        scheduleHideDateSeparators()
      }
    }

    private func scheduleHideDateSeparators() {
      // Cancel any existing scheduled hide operation
      dateSeparatorHideWorkItem?.cancel()

      let workItem = DispatchWorkItem { [weak self] in
        self?.setDateSeparators(hidden: true, animated: true)
      }
      dateSeparatorHideWorkItem = workItem
      DispatchQueue.main.asyncAfter(deadline: .now() + dateSeparatorHideDelay, execute: workItem)
    }

    private func getMessagesWindow(around targetMessageId: Int64) -> [Int64] {
      guard let targetIndex = messages.firstIndex(where: { $0.message.messageId == targetMessageId }) else {
        return []
      }

      let startIndex = max(0, targetIndex - 50)
      let endIndex = min(messages.count - 1, targetIndex + 50)

      return messages[startIndex ... endIndex].map(\.message.messageId)
    }

    private func createWillDoMenu(for message: Message) -> UIAction? {
      // Only show "Create Notion Task" if user has integration access
      guard NotionTaskManager.shared.hasAccess else { return nil }

      return UIAction(
        title: "Create Notion Task",
        image: UIImage(systemName: "circle.badge.plus")
      ) { _ in
        Task {
          await NotionTaskManager.shared.handleWillDoAction(for: message, spaceId: self.spaceId.validSpaceId)
        }
      }
    }

    private func createLinearIssueMenu(for message: Message) -> UIAction? {
      guard let text = message.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
      }

      // Only show in spaces that have Linear connected (avoid showing action in spaces without Linear).
      // For DMs, only show if the user has Linear connected in at least one space.
      if message.peerId.isThread {
        guard hasLinearConnected else { return nil }
        guard let linearTeamId, !linearTeamId.isEmpty else { return nil }
      } else {
        guard hasLinearConnected else { return nil }
      }

      return UIAction(
        title: "Create Linear Issue",
        image: UIImage(systemName: "circle.badge.plus")
      ) { _ in
        Task { [weak self] in
          guard let self else { return }

          if message.peerId.isThread {
            guard hasLinearConnected else { return }
            guard let linearTeamId, !linearTeamId.isEmpty else {
              ToastManager.shared.showToast(
                "Select a default Linear team in Space Integrations first.",
                type: .error,
                systemImage: "exclamationmark.triangle"
              )
              return
            }
            await createLinearIssue(text: text, message: message, spaceId: spaceId.validSpaceId)
            return
          }

          do {
            let integrations = try await InlineRPCClient.shared.integrations(
              userID: Auth.shared.getCurrentUserId() ?? 0,
              spaceID: nil
            )

            guard integrations.hasLinearConnected else {
              ToastManager.shared.showToast(
                "No Linear integration found. Connect Linear in one of your spaces.",
                type: .error,
                systemImage: "exclamationmark.triangle"
              )
              return
            }

            guard let linearSpaces = integrations.linearSpaces, !linearSpaces.isEmpty else {
              ToastManager.shared.showToast(
                "No accessible Linear integrations found",
                type: .error,
                systemImage: "exclamationmark.triangle"
              )
              return
            }

            showIntegrationSpaceSelectionSheet(
              title: "Select Space",
              message: "Choose which space to create the Linear issue in:",
              spaces: linearSpaces.map { (id: $0.spaceId, name: $0.spaceName) },
              completion: { selectedSpaceId in
                Task { [weak self] in
                  guard let self else { return }
                  do {
                    let perSpace = try await InlineRPCClient.shared.integrations(
                      userID: Auth.shared.getCurrentUserId() ?? 0,
                      spaceID: selectedSpaceId
                    )

                    guard perSpace.hasLinearConnected else {
                      ToastManager.shared.showToast(
                        "Linear isn’t connected for that space.",
                        type: .error,
                        systemImage: "exclamationmark.triangle"
                      )
                      return
                    }

                    guard let teamId = perSpace.linearTeamId, !teamId.isEmpty else {
                      ToastManager.shared.showToast(
                        "Select a default Linear team for that space first.",
                        type: .error,
                        systemImage: "exclamationmark.triangle"
                      )
                      return
                    }

                    await createLinearIssue(text: text, message: message, spaceId: selectedSpaceId)
                  } catch {
                    ToastManager.shared.showToast(
                      "Failed to fetch integrations for that space",
                      type: .error,
                      systemImage: "exclamationmark.triangle"
                    )
                  }
                }
              }
            )
          } catch {
            ToastManager.shared.showToast(
              "Failed to fetch integrations",
              type: .error,
              systemImage: "exclamationmark.triangle"
            )
          }
        }
      }
    }

    private func createLinearIssue(text: String, message: Message, spaceId: Int64?) async {
      ToastManager.shared.showToast(
        "Creating Linear issue…",
        type: .info,
        systemImage: "linear-icon",
        shouldStayVisible: true
      )

      do {
        guard let spaceId else { throw InlineRPCClientError.unexpectedResponse }
        let result = try await InlineRPCClient.shared.createLinearIssue(
          spaceID: spaceId,
          messageID: message.messageId,
          peerID: message.peerId
        )

        guard let link = result.link, let url = URL(string: link) else {
          ToastManager.shared.showToast(
            "Failed to create Linear issue",
            type: .error,
            systemImage: "exclamationmark.triangle"
          )
          return
        }

        ToastManager.shared.showToast(
          "Linear issue created",
          type: .success,
          systemImage: "checkmark.circle",
          action: {
            InAppBrowser.shared.open(url)
          },
          actionTitle: "Fast Open"
        )
      } catch {
        ToastManager.shared.showToast(
          "Failed to create Linear issue",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
      }
    }
  }
}

// MARK: - NotionTaskManagerDelegate Extension

extension MessagesCollectionView.Coordinator: InlineKit.NotionTaskManagerDelegate {
  func showErrorToast(_ message: String, systemImage: String) {
    DispatchQueue.main.async {
      ToastManager.shared.showToast(
        message,
        type: .error,
        systemImage: systemImage
      )
    }
  }

  func showSuccessToast(_ message: String, systemImage: String, url: String) {
    DispatchQueue.main.async {
      ToastManager.shared.showToast(
        message,
        type: .success,
        systemImage: systemImage,
        action: {
          if let url = URL(string: url) {
            InAppBrowser.shared.open(url)
          }
        },
        actionTitle: "Fast Open"
      )
    }
  }

  func showSpaceSelectionSheet(spaces: [InlineKit.NotionSpace], completion: @escaping @Sendable (Int64) -> Void) {
    showIntegrationSpaceSelectionSheet(
      title: "Select Space",
      message: "Choose which space to create the Notion task in the selected database:",
      spaces: spaces.map { (id: $0.spaceId, name: $0.spaceName) },
      completion: completion
    )
  }

  private func showIntegrationSpaceSelectionSheet(
    title: String,
    message: String,
    spaces: [(id: Int64, name: String)],
    completion: @escaping @Sendable (Int64) -> Void
  ) {
    // Ensure UI operations happen on the main thread
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }

      /// Find the view controller by traversing the responder chain from the collection view
      func findViewController(from view: UIView?) -> UIViewController? {
        guard let view else { return nil }

        var responder: UIResponder? = view
        while let nextResponder = responder?.next {
          if let viewController = nextResponder as? UIViewController {
            return viewController
          }
          responder = nextResponder
        }
        return nil
      }

      guard let viewController = findViewController(from: currentCollectionView) else { return }

      let alert = UIAlertController(
        title: title,
        message: message,
        preferredStyle: .actionSheet
      )

      for space in spaces {
        let action = UIAlertAction(title: space.name, style: .default) { _ in
          completion(space.id)
        }
        alert.addAction(action)
      }

      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

      // For iPad
      if let popover = alert.popoverPresentationController {
        popover.sourceView = viewController.view
        popover.sourceRect = CGRect(
          x: viewController.view.bounds.midX,
          y: viewController.view.bounds.midY,
          width: 0,
          height: 0
        )
        popover.permittedArrowDirections = []
      }

      viewController.present(alert, animated: true)
    }
  }

  func showProgressStep(_ step: Int, message: String, systemImage: String) {
    DispatchQueue.main.async {
      ToastManager.shared.showProgressStep(
        step,
        message: message,
        systemImage: systemImage
      )
    }
  }

  func updateProgressToast(message: String, systemImage: String) {
    DispatchQueue.main.async {
      ToastManager.shared.updateProgressToast(
        message: message,
        systemImage: systemImage
      )
    }
  }

  // MARK: - Translation Handling

  private func handleTranslationForUpdate(_ update: MessagesSectionedViewModel.SectionedMessagesChangeSet) {
    Task {
      await handleTranslationForUpdateInner(update)
    }
  }

  private func handleTranslationForUpdateInner(_ update: MessagesSectionedViewModel.SectionedMessagesChangeSet) async {
    switch update {
      case .reload:
        // For reload, trigger translation on all current messages
        let messages = viewModel.messages.filter { !$0.message.isServiceMessage }
        translationViewModel.messagesDisplayed(messages: messages)

        // Also analyze for translation detection on initial load
        if !hasAnalyzedInitialMessages, !messages.isEmpty {
          await TranslationDetector.shared.analyzeMessages(peer: peerId, messages: messages)
          hasAnalyzedInitialMessages = true
        }

      case let .messagesAdded(_, messageIds):
        // For added messages, get them from the viewModel and trigger translation
        let addedMessages = messageIds.compactMap { messageId in
          viewModel.messagesByID[messageId]
        }.filter { !$0.message.isServiceMessage }
        if !addedMessages.isEmpty {
          translationViewModel.messagesDisplayed(messages: addedMessages)

          // Also analyze new messages for translation detection if we haven't done initial analysis
          if !hasAnalyzedInitialMessages {
            await TranslationDetector.shared.analyzeMessages(peer: peerId, messages: addedMessages)
            hasAnalyzedInitialMessages = true
          }
        }

      case let .messagesUpdated(_, messageIds, _):
        // For updated messages, get them from the viewModel and trigger translation
        let updatedMessages = messageIds.compactMap { messageId in
          viewModel.messagesByID[messageId]
        }.filter { !$0.message.isServiceMessage }
        if !updatedMessages.isEmpty {
          translationViewModel.messagesDisplayed(messages: updatedMessages)
        }

      case let .sectionsChanged(sections):
        let changedMessages = sections.flatMap(\.messages).filter { !$0.message.isServiceMessage }
        if !changedMessages.isEmpty {
          translationViewModel.messagesDisplayed(messages: changedMessages)
        }

      case let .multiSectionUpdate(sections):
        let changedMessages = sections.flatMap(\.messages).filter { !$0.message.isServiceMessage }
        if !changedMessages.isEmpty {
          translationViewModel.messagesDisplayed(messages: changedMessages)
        }

      case .messagesDeleted:
        // No action needed for deletes
        break
    }
  }
}

private extension Int64? {
  var validSpaceId: Int64? {
    guard let self, self > 0 else { return nil }
    return self
  }
}
