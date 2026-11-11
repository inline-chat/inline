import AppKit
import Auth
import Combine
import InlineKit
import InlineMacUI
import InlineUI
import Logger
import os.signpost
import SwiftUI
import Throttler
import Translation

struct MessageListSelectionUpdate: Equatable, Sendable {
  let isActive: Bool
  let count: Int
  let selectedStableIds: [Int64]
  let selectedMessageIds: [Int64]
  let changedStableIds: Set<Int64>
}

class MessageListAppKit: NSViewController {
  // Data
  private var dependencies: AppDependencies
  private var peerId: Peer
  private var chat: Chat?
  private var chatId: Int64 {
    chat?.id ?? 0
  }

  private let chatRows: ChatRowListViewModel
  private let showUnreadAfter: Int64?
  /// Link/search target that owns the first viewport instead of the live bottom.
  private var initialTargetMessageId: Int64?
  /// Set while history around an uncached unread line is fetched; see `beginUnreadFetchIfNeeded`.
  private var unreadFetchBoundary: Int64?
  /// The saved reading place the chat opens at, placed in the first layout; see
  /// `placeInitialReadingPlaceIfNeeded`. Cleared once initial placement finishes.
  private var initialReadingPlace: ChatReadingPlace?
  private let initialPinnedMessage: PreparedPinnedMessage?
  private let surfaceStyle: ChatViewAppearance.SurfaceStyle
  private let additionalTopContentInset: CGFloat
  var viewModel: MessagesProgressiveViewModel {
    chatRows.progressiveViewModel
  }

  private var messages: [FullMessage] {
    chatRows.messages
  }

  var highestPositiveMessageId: Int64? {
    chatRows.highestPositiveMessageId
  }

  private var state: ChatState
  private let messageRenderStyle: MessageRenderStyle
  private let usesAvatarOverlay: Bool
  private var messageSelection = MessageSelectionState()
  private var showsForwardSelection = false
  var messageSelectionInset: CGFloat?
  var messageSelectionTableView: NSTableView {
    tableView
  }

  func canSelectMessage(atRow row: Int) -> Bool {
    selectableStableId(forRow: row) != nil
  }

  var onMessageSelectionChange: ((MessageListSelectionUpdate) -> Void)?

  var isMessageSelectionActive: Bool {
    messageSelection.isActive
  }

  var selectedMessageCount: Int {
    messageSelection.count
  }

  var selectedMessagesInLoadedOrder: [FullMessage] {
    selectedStableIdsInLoadedOrder().compactMap { messageAndIndex(forStableId: $0)?.message }
  }

  // MARK: - Interleaved chat rows (messages + UI-only rows)

  private let log = Log.scoped("MessageListAppKit")
  private let sizeCalculator = MessageSizeCalculator.shared
  private let defaultRowHeight: CGFloat = 45.0

  // Specification - mostly useful in debug
  private var feature_scrollsToBottomOnNewMessage = true
  private var feature_setupsInsetsManually = true
  private var feature_updatesHeightsOnWidthChange = true
  private var feature_recalculatesHeightsWhileInitialScroll = true
  private var feature_loadsMoreWhenApproachingTop = true
  private var feature_loadsMoreWhenApproachingBottom = true

  // Testing
  private var feature_updatesHeightsOnLiveResizeEnd = true

  /// Not needed
  private var feature_updatesHeightsOnOffsetChange = false

  // Debugging
  private var debug_slowAnimation = false
  private static let signpostLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")
  private var viewDidLayoutCount = 0
  private var heightRecalcCount = 0
  private var madeMessageCellCount = 0
  private var rowHeightQueryCount = 0
  private var didScheduleChatNavigationReady = false

  private var suppressResizeScrollMaintenance = false
  private let minimumAvailableMeasurementWidth: CGFloat = 80
  private var lastValidMeasurementWidth: CGFloat = 0
  private var didFinalizeInitialMeasurementWidth = false

  private var eventMonitorTask: Task<Void, Never>?
  private var integrationCheckTask: Task<Void, Never>?
  private var remoteOlderTask: Task<Void, Never>?
  private var remoteNewerTask: Task<Void, Never>?
  private var lastRemoteNewerAttempt: (messageID: Int64, date: Date)?
  private var targetScrollTask: Task<Void, Never>?
  private var targetScrollRevision: UInt64 = 0
  /// Focus target that is newer than the loaded live end and has not synced yet.
  private var pendingArrivalMessageID: Int64?
  private var loadBatchTask: Task<Void, Never>?
  private var heightPrecalcTask: Task<Void, Never>?
  private var mediaWarmupTask: Task<Void, Never>?
  private var mediaWarmups: [InlineTinyThumbnailWarmup] = []
  private var cancellables: Set<AnyCancellable> = []
  private var avatarOverlaySyncInProgress = false
  private var avatarOverlaySyncPending = false
  private var avatarOverlayNeedsRaise = false
  private var lastAvatarOverlayVisibleRange: NSRange?
  private var lastAvatarOverlayVisibleRect: CGRect?
  private var messageHoverTrackingArea: NSTrackingArea?
  private var hoveredMessageStableId: Int64?
  private weak var hoveredMessageCell: MessageTableCell?
  private var messageHoverRefreshScheduled = false
  private var messageQuickActionsView: MessageQuickActionsView?
  private var isQuickActionsMenuOpen = false
  private weak var quickActionsReactionOverlay: ReactionOverlayWindow?
  private var isQuickActionsPresentationOpen: Bool {
    isQuickActionsMenuOpen || quickActionsReactionOverlay?.isVisible == true
  }

  private var isDisposed = false
  private weak var observedToolbar: NSToolbar?
  private var toolbarDisplayModeObservation: NSKeyValueObservation?

  // Translation system
  private let translationViewModel: TranslationViewModel
  private var hasAnalyzedInitialMessages = false
  private var deferredTranslationTask: Task<Void, Never>?
  private var hasDeferredInitialTranslation = false
  private var lastVisibleReadCandidateID: Int64?
  private var lastVisibleReadCoverage: MessageHistoryCoverageProjection?
  private var appActivityObserverId: UUID?
  private var statusNoticeCancellable: AnyCancellable?

  init(
    dependencies: AppDependencies,
    peerId: Peer,
    chat: Chat,
    showUnreadAfter: Int64? = nil,
    initialState: MessagesProgressiveViewModel.InitialState? = nil,
    initialTargetMessageId: Int64? = nil,
    unreadFetchBoundary: Int64? = nil,
    collapsedMaxId: Int64? = nil,
    initialPinnedMessage: PreparedPinnedMessage? = nil,
    surfaceStyle: ChatViewAppearance.SurfaceStyle = .content,
    additionalTopContentInset: CGFloat = 0
  ) {
    self.dependencies = dependencies
    self.peerId = peerId
    self.chat = chat
    self.showUnreadAfter = showUnreadAfter
    self.initialTargetMessageId = initialTargetMessageId
    self.unreadFetchBoundary = initialTargetMessageId == nil ? unreadFetchBoundary : nil
    if initialTargetMessageId == nil, case let .saved(place)? = initialState?.openAnchor {
      initialReadingPlace = place
    }
    self.initialPinnedMessage = initialPinnedMessage
    self.surfaceStyle = surfaceStyle
    self.additionalTopContentInset = additionalTopContentInset
    chatRows = ChatRowListViewModel(
      peer: peerId,
      initialState: initialState,
      collapsedMaxId: collapsedMaxId
    )
    let renderStyle = AppSettings.shared.messageRenderStyle
    messageRenderStyle = renderStyle
    usesAvatarOverlay = AppConfig.macMessageAvatarOverlayEnabled
    state = ChatsManager
      .get(
        for: peerId,
        chatId: chat.id
      )
    translationViewModel = TranslationViewModel(peerId: peerId)

    super.init(nibName: nil, bundle: nil)

    pinnedHeaderHeight = initialPinnedMessage == nil ? 0 : PinnedMessageHeaderView.preferredHeight

    appActivityObserverId = AppActivityMonitor.shared.addObserver { [weak self] state in
      guard let self else { return }
      guard state == .active else {
        activityNavigator?.clearVisible()
        return
      }
      lastVisibleReadCandidateID = nil
      updateUnreadIfNeeded()
    }

    sizeCalculator.prepareForUse()
    observeStatusNotice()
    rebuildRowItems()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(richBlockLayoutStateDidChange),
      name: .richBlockLayoutStateDidChange,
      object: nil
    )

    // observe data
    chatRows.observe { [weak self] update in
      self?.applyUpdate(update)
      self?.handleTranslationForUpdate(update)

      switch update {
        case .added, .reload:
          self?.updateUnreadIfNeeded()

        default:
          break
      }
    }

    // observe events

    eventMonitorTask = Task { @MainActor [weak self] in
      guard let self_ = self else { return }

      for await event in self_.state.events {
        // Sending or jumping is newer intent than a pending unread landing.
        self_.endUnreadFetch(placesLine: false)
        switch event {
          case let .scrollToMsg(request):
            // scroll and highlight
            self_.scrollToMsgAndHighlight(request)

          case .scrollToBottom:
            // Sent from here (compose) or asked for: the chat reopens at its latest messages.
            ChatReadingPlaceStore.shared.clear(for: self_.peerId)
            if !self_.isWithinFollowZone || self_.chatRows.canLoadNewerFromLocal {
              self_.scrollToNewestAvailable(animated: true)
            }
        }
      }
    }

    TranslationState.shared.subject.sink { [weak self] _ in
      guard let self else { return }

      // Invalidate message text cache
      CacheAttrs.shared.invalidate()

      // Invalidate message view heights
      MessageSizeCalculator.shared.invalidateCache()

      // Reload to reflect changes
      // applyUpdate(.reload(animated: true))
      applyUpdate(.reload(animated: false))
    }.store(in: &cancellables)

    AppSettings.shared.$translationUIEnabled
      .receive(on: DispatchQueue.main)
      .sink { [weak self] enabled in
        guard let self else { return }
        if !enabled {
          // Stop any pending work and clear "already analyzed" flags so re-enabling works.
          deferredTranslationTask?.cancel()
          deferredTranslationTask = nil
          hasAnalyzedInitialMessages = false
          hasDeferredInitialTranslation = false
        }
      }
      .store(in: &cancellables)

    AppSettings.shared.$toolbarStyle
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.scheduleToolbarBackgroundUpdate()
      }
      .store(in: &cancellables)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private lazy var toolbarBgView = ToolbarBackgroundView(surfaceStyle: surfaceStyle)
  private var pinnedHeaderHeight: CGFloat = 0
  /// Height of a bar floating under the toolbar (in-chat search). Messages start below it,
  /// and the pinned header hides meanwhile, as in Telegram: its glass under the search
  /// panel's glass would flatten both.
  private var topOverlayHeight: CGFloat = 0
  private var visiblePinnedHeaderHeight: CGFloat {
    topOverlayHeight > 0 ? 0 : pinnedHeaderHeight
  }
  private var pinnedHeaderTopConstraint: NSLayoutConstraint?
  private var pinnedHeaderHeightConstraint: NSLayoutConstraint?
  private lazy var pinnedHeaderView: PinnedMessageHeaderView = {
    let view = PinnedMessageHeaderView(
      dependencies: dependencies,
      peerId: peerId,
      chatId: chatId,
      initialPinnedMessage: initialPinnedMessage
    )
    view.onHeightChange = { [weak self] height in
      guard let self else { return }
      pinnedHeaderHeight = height
      pinnedHeaderHeightConstraint?.constant = height
      applyPinnedHeaderSuppression()
      updateScrollViewInsets()
    }
    return view
  }()

  private func rebuildRowItems() {
    _ = chatRows.rebuildFromViewModel(showUnreadAfter: showUnreadAfter)
  }

  private func rowItem(at row: Int) -> ChatRowListViewModel.Row? {
    chatRows.row(at: row)
  }

  /// The DM peer whose status the line under the newest message describes.
  private var statusNoticeUserId: Int64? {
    guard let userId = peerId.asUserId(), userId != Auth.shared.getCurrentUserId() else { return nil }
    return userId
  }

  private func observeStatusNotice() {
    guard let userId = statusNoticeUserId else { return }
    // Seeds the first frame from memory; rows are built right after.
    _ = chatRows.setStatusNotice(ObjectCache.shared.getCachedUser(id: userId)?.notificationsSilencedNotice())
    statusNoticeCancellable = ObjectCache.shared.getUserPublisher(id: userId)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] userInfo in
        guard let userInfo else { return }
        self?.setStatusNotice(userInfo.notificationsSilencedNotice())
      }
  }

  /// The notice is the last row, so it never moves rows above it. A pinned list follows it.
  private func setStatusNotice(_ text: String?) {
    guard !isDisposed else { return }
    let wasAtBottom = isViewLoaded && shouldKeepBottomPinned
    let anchors = isViewLoaded && !wasAtBottom ? viewport.anchors() : []
    let update = chatRows.setStatusNotice(text)
    guard update != .none, isViewLoaded else { return }

    let animate = wasAtBottom && !needsInitialScroll && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let apply = { [self] in
      let animation: NSTableView.AnimationOptions = animate ? .effectFade : []
      switch update {
        case let .insert(rows): tableView.insertRows(at: rows, withAnimation: animation)
        case let .remove(rows): tableView.removeRows(at: rows, withAnimation: animation)
        case let .reloadRows(rows):
          tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        case .reloadAll, .none:
          tableView.reloadData()
          tableView.layoutSubtreeIfNeeded()
          if let anchor = anchors.first(where: { viewport.index(of: $0) != nil }) {
            viewport.restore(anchor)
          }
      }
      if wasAtBottom {
        scrollToBottom(animated: animate)
      }
    }

    if animate {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        apply()
      }
    } else {
      apply()
    }
  }

  func collapseHistory(maxID: Int64?) async throws {
    let effectiveMaxID = try await Api.realtime.collapseHistory(peer: peerId.toInputPeer(), maxID: maxID)
    setCollapsedMaxId(effectiveMaxID)
  }

  func setCollapsedMaxId(_ collapsedMaxId: Int64?) {
    let wasAtBottom = isViewLoaded && shouldKeepBottomPinned
    let anchors = isViewLoaded ? viewport.anchors() : []
    guard chatRows.setCollapsedMaxId(collapsedMaxId) != .none, isViewLoaded else { return }

    clearHoveredMessage()
    tableView.reloadData()
    tableView.layoutSubtreeIfNeeded()
    if wasAtBottom {
      scrollToBottom(animated: false)
    } else if let anchor = anchors.first(where: { viewport.index(of: $0) != nil }) {
      viewport.restore(anchor)
    }
    syncAvatarOverlayAfterTableLayout()
    scheduleMediaWarmupForVisibleAndNearby(reason: "collapse_boundary")
  }

  private var viewport: MessageListViewport {
    MessageListViewport(table: tableView, scroll: scrollView, rows: chatRows)
  }

  private typealias VisibleMessageAnchor = MessageListViewport.Anchor

  private func messageStableId(forRow row: Int) -> Int64? {
    chatRows.messageStableId(forRow: row)
  }

  private func usesAvatarOverlay(forRow row: Int) -> Bool {
    guard usesAvatarOverlay else { return false }
    if case .parentMessage? = rowItem(at: row) {
      return false
    }
    if message(forRow: row)?.message.isServiceMessage == true {
      return false
    }
    return true
  }

  private var selectableMessageStableIds: [Int64] {
    messages.filter { isForwardSelectable($0) }.map(\.id)
  }

  private func selectableStableId(forRow row: Int) -> Int64? {
    guard chatRows.canSelect(row: row), let message = message(forRow: row),
          isForwardSelectable(message) else { return nil }
    return messageStableId(forRow: row)
  }

  private func selectedStableIdsInLoadedOrder() -> [Int64] {
    messageSelection.orderedSelection(in: selectableMessageStableIds)
  }

  private func selectedMessageIdsInLoadedOrder() -> [Int64] {
    selectedMessagesInLoadedOrder.map(\.message.messageId)
  }

  func isMessageSelected(atRow row: Int) -> Bool {
    guard let stableId = selectableStableId(forRow: row) else { return false }
    return messageSelection.isSelected(stableId)
  }

  func messageSelectionStableId(atRow row: Int) -> Int64? {
    selectableStableId(forRow: row)
  }

  func messageSelectionRow(forStableId stableId: Int64) -> Int? {
    chatRows.rowIndex(forMessageStableId: stableId)
  }

  var selectedMessageStableIds: Set<Int64> {
    messageSelection.selectedStableIds
  }

  func setSelectedMessageStableIds(_ stableIds: Set<Int64>) {
    let changed = messageSelection.replace(with: stableIds, orderedIds: selectableMessageStableIds)
    emitMessageSelectionChange(changedStableIds: changed)
  }

  @discardableResult
  func beginMessageSelection(atRow row: Int) -> Bool {
    guard let stableId = selectableStableId(forRow: row) else { return false }
    let changed = messageSelection.begin(with: stableId)
    emitMessageSelectionChange(changedStableIds: changed)
    return true
  }

  @discardableResult
  func toggleMessageSelection(atRow row: Int) -> Bool {
    guard let stableId = selectableStableId(forRow: row) else { return false }
    let changed = messageSelection.toggle(stableId, orderedIds: selectableMessageStableIds)
    emitMessageSelectionChange(changedStableIds: changed)
    return true
  }

  @discardableResult
  func extendMessageSelection(toRow row: Int) -> Bool {
    guard let stableId = selectableStableId(forRow: row) else { return false }
    let changed = messageSelection.selectRange(to: stableId, orderedIds: selectableMessageStableIds)
    emitMessageSelectionChange(changedStableIds: changed)
    return true
  }

  @discardableResult
  func selectAllMessages() -> Bool {
    let stableIds = selectableMessageStableIds
    let changed = messageSelection.selectAll(stableIds)
    emitMessageSelectionChange(changedStableIds: changed)
    return !stableIds.isEmpty
  }

  @discardableResult
  func clearMessageSelection() -> Bool {
    let changed = messageSelection.clear()
    emitMessageSelectionChange(changedStableIds: changed)
    return !changed.isEmpty
  }

  @discardableResult
  private func pruneMessageSelection() -> Bool {
    guard messageSelection.isActive else { return false }
    let stableIds = selectableMessageStableIds
    let changed = messageSelection.prune(validIds: Set(stableIds), orderedIds: stableIds)
    emitMessageSelectionChange(changedStableIds: changed)
    return !changed.isEmpty
  }

  private func emitMessageSelectionChange(changedStableIds: Set<Int64>) {
    refreshForwardSelection()
    guard !changedStableIds.isEmpty else { return }
    hideMessageQuickActions()
    scheduleMessageHoverRefresh()
    onMessageSelectionChange?(
      MessageListSelectionUpdate(
        isActive: messageSelection.isActive,
        count: messageSelection.count,
        selectedStableIds: selectedStableIdsInLoadedOrder(),
        selectedMessageIds: selectedMessageIdsInLoadedOrder(),
        changedStableIds: changedStableIds
      )
    )
  }

  private func isForwardSelectable(_ fullMessage: FullMessage) -> Bool {
    let message = fullMessage.message
    return message.messageId > 0 && !message.isServiceMessage && !message.isSubthreadPlacement
      && (message.status == nil || message.status == .sent)
  }

  private func refreshForwardSelection() {
    guard isViewLoaded else { return }
    let active = messageSelection.isActive
    let modeChanged = showsForwardSelection != active
    // Snapshot the old geometry before exposing the new measurement width or changing cell constraints.
    let anchor = modeChanged ? viewport.anchors().first : nil
    let wasAtBottom = shouldKeepBottomPinned
    let wasSuppressingResize = suppressResizeScrollMaintenance
    if modeChanged {
      tableUpdateCount += 1
      suppressResizeScrollMaintenance = true
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      NSAnimationContext.beginGrouping()
      NSAnimationContext.current.duration = 0
      NSAnimationContext.current.allowsImplicitAnimation = false
    }
    defer {
      if modeChanged {
        // Refresh the resize handler's baseline after restoring the viewport, before releasing the guard.
        handleBoundsChange()
        NSAnimationContext.endGrouping()
        CATransaction.commit()
        endTableUpdate()
        suppressResizeScrollMaintenance = wasSuppressingResize
      }
    }
    showsForwardSelection = active
    if modeChanged, let width = measurementWidth() {
      // This transition owns the width update; viewDidLayout must not run a second resize pass.
      lastKnownWidth = width
    }
    tableView.selectionHighlightStyle = .none
    tableView.deselectAll(nil)
    let visible = tableView.rows(in: tableView.visibleRect)
    if visible.location != NSNotFound {
      for row in visible.location ..< min(NSMaxRange(visible), tableView.numberOfRows) {
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCell {
          configureForwardSelection(cell, row: row, animated: true)
        }
      }
    }

    if modeChanged {
      tableView.beginUpdates()
      if visible.location != NSNotFound {
        updateHeightsForRows(at: IndexSet(integersIn: visible.location ..< min(
          NSMaxRange(visible),
          tableView.numberOfRows
        )))
      }
      tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0 ..< tableView.numberOfRows))
      tableView.endUpdates()
      view.layoutSubtreeIfNeeded()
      if wasAtBottom {
        scrollToBottom(animated: false)
      } else if let anchor {
        viewport.restore(anchor)
      }
      maintainReadingHoldIfNeeded()
      syncAvatarOverlayAfterTableLayout()
      // Avatars live in one overlay; they all move with the message column, so slide it as a whole.
      if usesAvatarOverlay {
        SelectionMotion.slide(
          avatarOverlayView.layer,
          fromX: active ? -MessageTableCell.forwardSelectionInset : MessageTableCell.forwardSelectionInset
        )
      }
    }
  }

  private func configureForwardSelection(_ cell: MessageTableCell, row: Int, animated: Bool = false) {
    let stableId = selectableStableId(forRow: row)
    cell.setForwardSelection(
      active: messageSelection.isActive,
      selectable: stableId != nil,
      selected: stableId.map { messageSelection.isSelected($0) } ?? false,
      animated: animated
    ) { [weak self] in
      guard let self, let stableId, let currentRow = chatRows.rowIndex(forMessageStableId: stableId) else { return }
      toggleMessageSelection(atRow: currentRow)
    }
  }

  // MARK: - Reply thread side pane source

  /// Thread showing in this window's side pane while this chat is the primary chat.
  private var replyThreadPanePeer: Peer?
  private var replyThreadSourceMessageId: Int64?
  /// Holds the source message's viewport offset while the pane slides in or out.
  private var replyThreadSourceAnchor: VisibleMessageAnchor?
  /// A reader resting at latest when the pane moves keeps following it while the source still fits.
  private var replyThreadSourceKeepsBottom = false
  private var replyThreadSourceAnchorWidth: CGFloat?
  private var replyThreadSourceAnchorExpiry: DispatchWorkItem?
  private var isObservingReplyThreadPane = false

  /// Long enough to cover the pane's open and close animations plus a frame of slack.
  private static let replyThreadSourceAnchorDuration: TimeInterval = 0.4

  private func observeReplyThreadPane() {
    guard !isDisposed, let nav3 = dependencies.nav3 else { return }
    let isInitial = !isObservingReplyThreadPane
    isObservingReplyThreadPane = true
    let threadPeer = withObservationTracking {
      nav3.currentReplyThreadPeer
    } onChange: { [weak self] in
      // Fires on willSet; read the new value on the next main-actor turn. The pane's
      // first width change lands on a later display frame, after this has run.
      Task { @MainActor [weak self] in
        self?.observeReplyThreadPane()
      }
    }

    let panePeer = threadPeer == peerId ? nil : threadPeer
    let sourceMessageId = panePeer.flatMap {
      nav3.replyThreadSourceMessageId(threadPeer: $0, parentPeer: peerId)
    }
    guard panePeer != replyThreadPanePeer || sourceMessageId != replyThreadSourceMessageId else { return }

    let previousPanePeer = replyThreadPanePeer
    let previousSourceMessageId = replyThreadSourceMessageId
    replyThreadPanePeer = panePeer
    replyThreadSourceMessageId = sourceMessageId

    if !isInitial, isViewLoaded {
      // Opening anchors the new source; closing anchors the one that is leaving.
      captureReplyThreadSourceAnchor(
        threadPeer: panePeer ?? previousPanePeer,
        sourceMessageId: panePeer == nil ? previousSourceMessageId : sourceMessageId
      )
    }
    refreshReplyThreadSourceHighlights(animated: !isInitial)
  }

  private func isReplyThreadSource(
    _ message: FullMessage,
    threadPeer: Peer?,
    sourceMessageId: Int64?
  ) -> Bool {
    if let sourceMessageId, message.message.messageId == sourceMessageId {
      return true
    }
    guard let threadPeer else { return false }
    return message.message.replyThreadPeer == threadPeer
  }

  private func isReplyThreadSourceRow(_ row: Int) -> Bool {
    guard replyThreadPanePeer != nil,
          case .message? = rowItem(at: row),
          let message = message(forRow: row)
    else { return false }
    return isReplyThreadSource(
      message,
      threadPeer: replyThreadPanePeer,
      sourceMessageId: replyThreadSourceMessageId
    )
  }

  private func configureReplyThreadSourceHighlight(_ cell: MessageTableCell, row: Int, animated: Bool = false) {
    cell.setReplyThreadSourceHighlighted(isReplyThreadSourceRow(row), animated: animated)
  }

  private func refreshReplyThreadSourceHighlights(animated: Bool) {
    guard isViewLoaded else { return }
    let visible = tableView.rows(in: tableView.visibleRect)
    guard visible.location != NSNotFound else { return }
    for row in visible.location ..< min(NSMaxRange(visible), tableView.numberOfRows) {
      if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCell {
        configureReplyThreadSourceHighlight(cell, row: row, animated: animated)
      }
    }
  }

  private func captureReplyThreadSourceAnchor(threadPeer: Peer?, sourceMessageId: Int64?) {
    clearReplyThreadSourceAnchor()
    guard !needsInitialScroll, threadPeer != nil || sourceMessageId != nil else { return }

    let visibleRect = tableView.visibleRect
    let visible = tableView.rows(in: visibleRect)
    guard visible.location != NSNotFound else { return }

    for row in visible.location ..< min(NSMaxRange(visible), tableView.numberOfRows) {
      guard case .message? = rowItem(at: row),
            let message = message(forRow: row),
            isReplyThreadSource(message, threadPeer: threadPeer, sourceMessageId: sourceMessageId),
            let stableId = messageStableId(forRow: row)
      else { continue }

      // Opening or closing a thread is newer intent than the unread or saved landing; two
      // holds would fight, and the reading one runs last.
      releaseReadingHold()
      replyThreadSourceAnchor = VisibleMessageAnchor(
        id: .message(id: stableId), oldIndex: row,
        offset: tableView.rect(ofRow: row).minY - visibleRect.minY
      )
      replyThreadSourceKeepsBottom = viewport.distanceFromBottom <= Self.exactBottomTolerance
      replyThreadSourceAnchorWidth = measurementWidth()

      let expiry = DispatchWorkItem { [weak self] in
        self?.finishReplyThreadSourceAnchor()
      }
      replyThreadSourceAnchorExpiry = expiry
      DispatchQueue.main.asyncAfter(deadline: .now() + Self.replyThreadSourceAnchorDuration, execute: expiry)
      return
    }
  }

  private func clearReplyThreadSourceAnchor() {
    replyThreadSourceAnchorExpiry?.cancel()
    replyThreadSourceAnchorExpiry = nil
    replyThreadSourceAnchor = nil
    replyThreadSourceKeepsBottom = false
    replyThreadSourceAnchorWidth = nil
  }

  private func finishReplyThreadSourceAnchor() {
    let startWidth = replyThreadSourceAnchorWidth
    clearReplyThreadSourceAnchor()
    guard !isDisposed, let startWidth, let width = measurementWidth(), abs(width - startWidth) > 0.5 else { return }
    // Per-frame passes only remeasure visible rows; settle the rest like a finished live resize.
    fullWidthAsyncCalc()
  }

  /// Runs last in `viewDidLayout`, after width remeasurement. A reader who was resting at latest
  /// is kept there by the remeasurement while `replyThreadSourceKeepsBottom` holds.
  private func maintainReplyThreadSourceAnchorIfNeeded() {
    guard let anchor = replyThreadSourceAnchor,
          !isUserScrolling,
          !isPerformingUpdate,
          !needsInitialScroll,
          let row = viewport.index(of: anchor)
    else { return }

    let rowRect = tableView.rect(ofRow: row)
    let bounds = scrollView.contentView.bounds
    let insets = scrollView.contentInsets
    let visibleTop = bounds.minY + insets.top
    let visibleBottom = bounds.maxY - insets.bottom

    // Staying pinned to the live bottom wins while the source is still fully visible there.
    if viewport.distanceFromBottom <= Self.exactBottomTolerance, rowRect.minY >= visibleTop, rowRect.maxY <= visibleBottom {
      return
    }
    // Keeping the source in view now means leaving latest; later passes must not pull it back down.
    replyThreadSourceKeepsBottom = false

    var target = rowRect.minY - anchor.offset
    // Rewrapping can grow the row; keep all of it inside the unobscured viewport.
    if rowRect.maxY > target + bounds.height - insets.bottom {
      target = rowRect.maxY - bounds.height + insets.bottom
    }
    if rowRect.minY < target + insets.top {
      target = rowRect.minY - insets.top
    }
    target = clampScrollOffset(target)
    guard abs(target - bounds.minY) >= 0.5 else { return }
    scrollView.contentView.updateBounds(NSPoint(x: 0, y: target), cancel: true)
  }

  private var threadAnchor: FullMessage? {
    chatRows.threadAnchor
  }

  private func messageAndIndex(forStableId stableId: Int64) -> (message: FullMessage, index: Int?)? {
    if let messageIndex = chatRows.messageIndex(forStableMessageId: stableId),
       messages.indices.contains(messageIndex)
    {
      return (messages[messageIndex], messageIndex)
    }

    if let threadAnchor, threadAnchor.id == stableId {
      return (threadAnchor, nil)
    }

    return nil
  }

  private func interactionMode(for row: Int) -> MessageInteractionMode {
    if case .parentMessage? = rowItem(at: row) {
      return .threadAnchor
    }
    return .normal
  }

  private func setToolbarVisible(_ visible: Bool, animated: Bool) {
    let alpha: CGFloat = visible ? 1 : 0
    guard isToolbarVisible != visible || toolbarBgView.alphaValue != alpha else { return }
    isToolbarVisible = visible

    guard animated else {
      toolbarBgView.alphaValue = alpha
      return
    }

    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.08
      context.allowsImplicitAnimation = true

      toolbarBgView.alphaValue = alpha
    }
  }

  private lazy var tableView: NSTableView = {
    let table = NSTableView()
    table.style = .plain
    table.backgroundColor = .clear
    table.headerView = nil
    table.rowSizeStyle = .custom
    table.selectionHighlightStyle = .none
    table.allowsMultipleSelection = false

    table.intercellSpacing = NSSize(width: 0, height: 0)
    table.usesAutomaticRowHeights = false
    table.rowHeight = defaultRowHeight

    let column = NSTableColumn(identifier: .init("messageColumn"))
    column.isEditable = false
    // column.resizingMask = .autoresizingMask // v important
    column.resizingMask = [] // v important
    // Important: Set these properties

    table.addTableColumn(column)

    // Enable automatic resizing
    table.autoresizingMask = [.height]
    table.delegate = self
    table.dataSource = self

    // Optimize performance
    table.wantsLayer = true
    table.layerContentsRedrawPolicy = .onSetNeedsDisplay // could try .never too
    table.layer?.drawsAsynchronously = true
    // Centered chats make the table narrower than the viewport. Swipe-to-reply moves a
    // message and its reply arrow past the table's edges, so let them draw into the margins.
    table.clipsToBounds = false

    return table
  }()

  private lazy var scrollView: MessageListScrollView = {
    let scroll = MessageListScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    scroll.backgroundColor = .clear
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = tableView
    scroll.scrollerStyle = .overlay
    scroll.autoresizesSubviews = true // NEW

    scroll.verticalScrollElasticity = .allowed
    scroll.autohidesScrollers = true
    scroll.verticalScroller?.controlSize = .small // This makes it ultra-minimal
    scroll.postsBoundsChangedNotifications = true
    scroll.postsFrameChangedNotifications = true
    scroll.automaticallyAdjustsContentInsets = !feature_setupsInsetsManually

    // Optimize performance
    scroll.wantsLayer = true
    scroll.layerContentsRedrawPolicy = .onSetNeedsDisplay
    scroll.layer?.drawsAsynchronously = true

    return scroll
  }()

  private lazy var avatarOverlayView = MessageAvatarOverlayView()
  private var avatarOverlayStickyViewportInset: CGFloat {
    switch avatarOverlayStickyMode {
      case .bottom:
        if #available(macOS 26.0, *) {
          return 0
        }
        return 8
      case .top:
        return 8
    }
  }

  private var avatarOverlayStickyMode: MessageAvatarStickyMode {
    switch messageRenderStyle {
      case .bubble:
        .bottom
      case .minimal:
        .top
    }
  }

  private let avatarOverlayGroupCalendar = Calendar.autoupdatingCurrent

  private var scrollToBottomBottomConstraint: NSLayoutConstraint!
  private var activityJumpBottomConstraint: NSLayoutConstraint!
  private var reactionJumpBottomConstraint: NSLayoutConstraint!
  private var activityNavigator: ChatActivityNavigator?
  private var isScrollToBottomButtonShown = false
  private lazy var activityJumpButton: ActivityJumpButtonHostingView = {
    let button = ActivityJumpButtonHostingView(kind: .mention)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.onClick = { [weak self] in self?.jumpToNextActivity() }
    button.onMarkAllRead = { [weak self] in self?.activityNavigator?.markAllMentionsRead() }
    return button
  }()

  private lazy var reactionJumpButton: ActivityJumpButtonHostingView = {
    let button = ActivityJumpButtonHostingView(kind: .reaction)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.onClick = { [weak self] in self?.jumpToNextReaction() }
    button.onMarkAllRead = { [weak self] in self?.activityNavigator?.markAllReactionsRead() }
    return button
  }()

  private lazy var scrollToBottomButton: ScrollToBottomButtonHostingView = {
    let scrollToBottomButton = ScrollToBottomButtonHostingView()
    scrollToBottomButton.onClick = { [weak self] in
      guard let weakSelf = self else { return }
      weakSelf.scrollToNewestAvailable(animated: true)
      weakSelf.setScrollToBottomButtonShown(false)
    }
    scrollToBottomButton.translatesAutoresizingMaskIntoConstraints = false
    scrollToBottomButton.setVisibility(false)

    return scrollToBottomButton
  }()

  override func loadView() {
    view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    setupViews()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupScrollObserver()
    setupMessageHoverTracking()
    observeReplyThreadPane()
    hideScrollbars() // until initial scroll is done

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?.enableScrollbars()
    }

    log.trace("viewDidLoad for chat \(chatId)")
    beginUnreadFetchIfNeeded()

    integrationCheckTask?.cancel()
    integrationCheckTask = Task { [weak self] in
      guard let self, let chat else { return }
      await Task.yield()
      guard !Task.isCancelled else { return }
      await NotionTaskService.shared.checkIntegrationAccess(peerId: peerId, spaceId: chat.spaceId)
    }
  }

  // MARK: - Insets

  private var insetForCompose: CGFloat = Theme.composeMinHeight
  func updateInsetForCompose(_ inset: CGFloat, animate: Bool = true) {
    let inset = messageSelectionInset ?? inset
    let shouldFollow = canFollowBottom && isWithinFollowZone
    insetForCompose = inset

    scrollView.contentInsets.bottom = Theme.messageListBottomInset + insetForCompose
    // TODO: make quick changes smoother. currently it jitters a little

    // TODO:
    if animate {
      scrollToBottomBottomConstraint
        .animator().constant = -(Theme.messageListBottomInset + insetForCompose)
    } else {
      scrollToBottomBottomConstraint.constant = -(Theme.messageListBottomInset + insetForCompose)
    }
    updateActivityJumpPosition(animate: animate)

    if shouldFollow {
      tableView.scrollToBottomWithInset(cancel: false)
    }

    scheduleAvatarOverlaySync()
  }

  private func setInsets() {
    // TODO: extract insets logic from bottom here.
  }

  private var toolbarHeight: CGFloat = Theme.toolbarHeight
  private var toolbarBgHeightConstraint: NSLayoutConstraint?

  private func observeToolbarDisplayModeIfNeeded() {
    guard let toolbar = view.window?.toolbar else { return }
    guard observedToolbar !== toolbar else { return }

    toolbarDisplayModeObservation?.invalidate()
    observedToolbar = toolbar
    toolbarDisplayModeObservation = toolbar.observe(\.displayMode, options: [.initial, .new]) { [weak self] _, _ in
      self?.scheduleToolbarBackgroundUpdate()
    }
  }

  private func scheduleToolbarBackgroundUpdate() {
    updateToolbarBackgroundForStyleChange()

    DispatchQueue.main.async { [weak self] in
      self?.updateToolbarBackgroundForStyleChange()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
      self?.updateToolbarBackgroundForStyleChange()
    }
  }

  private func updateToolbarBackgroundForStyleChange() {
    guard isViewLoaded else { return }
    updateScrollViewInsets()
    view.needsLayout = true
  }

  /// This fixes the issue with the toolbar messing up initial content insets on window open. Now we call it on did
  /// layout and it fixes the issue.
  private func updateScrollViewInsets() {
    guard feature_setupsInsetsManually else { return }
    guard let window = view.window else { return }

    let windowFrame = window.frame
    let contentFrame = window.contentLayoutRect
    let chromeHeight = windowFrame.height - contentFrame.height
    let toolbarHeight = chromeHeight
    self.toolbarHeight = toolbarHeight
    toolbarBgHeightConstraint?.constant = toolbarHeight
    let topInset = toolbarHeight + additionalTopContentInset + topOverlayHeight + visiblePinnedHeaderHeight

    pinnedHeaderTopConstraint?.constant = toolbarHeight + additionalTopContentInset
    pinnedHeaderHeightConstraint?.constant = pinnedHeaderHeight

    if scrollView.contentInsets.top != topInset {
      log.trace("Adjusting view's insets")

      let wasAtBottom = canFollowBottom && viewport.distanceFromBottom <= Self.exactBottomTolerance
      let topAnchor = captureTopAnchor()
      suppressResizeScrollMaintenance = true

      scrollView.contentInsets = NSEdgeInsets(
        top: topInset,
        left: 0,
        bottom: Theme.messageListBottomInset + insetForCompose,
        right: 0
      )
      scrollView.scrollerInsets = NSEdgeInsets(
        top: 0,
        left: 0,
        bottom: -Theme.messageListBottomInset, // Offset it to touch bottom
        right: 0
      )

      updateToolbar()

      if readingHold != nil {
        // A pinned header appearing, even before the first frame settles, moves the
        // held row under the new inset, as Telegram re-pins it in the same pass.
        maintainReadingHoldIfNeeded()
      } else if !needsInitialScroll {
        if wasAtBottom {
          scrollToBottom(animated: false)
        } else if let topAnchor {
          restoreTopAnchor(topAnchor)
        }
      }

      DispatchQueue.main.async { [weak self] in
        self?.suppressResizeScrollMaintenance = false
      }
    }
  }

  private struct TopAnchorSnapshot {
    let row: Int
    let offset: CGFloat
  }

  private func captureTopAnchor() -> TopAnchorSnapshot? {
    let visibleRect = tableView.visibleRect
    let range = tableView.rows(in: visibleRect)
    guard range.location != NSNotFound, range.length > 0 else { return nil }

    let row = range.location
    let rowRect = tableView.rect(ofRow: row)
    return TopAnchorSnapshot(row: row, offset: rowRect.minY - visibleRect.minY)
  }

  private func restoreTopAnchor(_ anchor: TopAnchorSnapshot) {
    scrollView.layoutSubtreeIfNeeded()
    let rowRect = tableView.rect(ofRow: anchor.row)
    let targetVisibleMinY = rowRect.minY - anchor.offset
    let clamped = clampScrollOffset(targetVisibleMinY)
    scrollView.contentView.updateBounds(NSPoint(x: 0, y: clamped), cancel: true)
  }

  /// The origin AppKit will accept nearest to `offset`: its range includes the content insets
  /// (from `-top` to `document + bottom - viewport`) and its limits snap to the pixel grid.
  /// Clamping to `0 ... document - viewport` instead moved a restored row by up to an inset
  /// near either end of the history (open-at-unread lab, 2026-11-08).
  private func clampScrollOffset(_ offset: CGFloat) -> CGFloat {
    let clip = scrollView.contentView
    return clip.constrainBoundsRect(
      NSRect(x: clip.bounds.minX, y: offset, width: clip.bounds.width, height: clip.bounds.height)
    ).minY
  }

  private func isAtTop() -> Bool {
    let scrollOffset = scrollView.contentView.bounds.origin
    let topOffset = min(-scrollView.contentInsets.top, 0)
    return scrollOffset.y <= topOffset + 0.5
  }

  private func userVisibleRect() -> NSRect {
    tableView.visibleRect.insetBy(
      dx: 0,
      dy: -scrollView.contentInsets.bottom - scrollView.contentInsets.top
    )
  }

  private func updateMessageViewColors() {
    let visibleRange = tableView.rows(in: userVisibleRect())
    guard visibleRange.location != NSNotFound, visibleRange.length > 0 else { return }

    let upperBound = min(NSMaxRange(visibleRange), tableView.numberOfRows)
    for row in visibleRange.location ..< upperBound {
      guard let cell = tableView.view(
        atColumn: 0,
        row: row,
        makeIfNecessary: false
      ) as? MessageTableCell else { continue }
      cell.reflectBoundsChange(fraction: 0)
    }
  }

  private var isToolbarVisible: Bool?

  private var usesToolbarBgView: Bool {
    if #available(macOS 27.0, *) {
      return true
    }
    if #available(macOS 26.0, *) {
      return false
    }
    return true
  }

  private var fadesToolbarBgView: Bool {
    if #available(macOS 26.0, *) {
      return false
    }
    return true
  }

  private func updateToolbar() {
    guard usesToolbarBgView else {
      isToolbarVisible = false
      return
    }

    let atTop = isAtTop()
    setToolbarVisible(!atTop, animated: fadesToolbarBgView)
  }

  private func setupViews() {
    view.addSubview(scrollView)

    // Set up constraints
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    installAvatarOverlayIfNeeded(raise: true)

    if usesToolbarBgView {
      view.addSubview(toolbarBgView)
      let heightConstraint = toolbarBgView.heightAnchor.constraint(equalToConstant: toolbarHeight)
      toolbarBgHeightConstraint = heightConstraint

      NSLayoutConstraint.activate([
        toolbarBgView.topAnchor.constraint(equalTo: view.topAnchor),
        toolbarBgView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        toolbarBgView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        heightConstraint,
      ])
    }

    view.addSubview(pinnedHeaderView)
    pinnedHeaderTopConstraint = pinnedHeaderView.topAnchor.constraint(
      equalTo: view.topAnchor,
      constant: toolbarHeight + additionalTopContentInset
    )
    pinnedHeaderHeightConstraint = pinnedHeaderView.heightAnchor.constraint(equalToConstant: pinnedHeaderHeight)

    NSLayoutConstraint.activate([
      pinnedHeaderTopConstraint!,
      pinnedHeaderView.leadingAnchor.constraint(equalTo: scrollView.messageColumnGuide.leadingAnchor),
      pinnedHeaderView.trailingAnchor.constraint(equalTo: scrollView.messageColumnGuide.trailingAnchor),
      pinnedHeaderHeightConstraint!,
    ])

    // Set column width to match scroll view width
    // updateColumnWidth()

    // Add the button
    view.addSubview(scrollToBottomButton)

    scrollToBottomBottomConstraint = scrollToBottomButton.bottomAnchor.constraint(
      equalTo: view.bottomAnchor,
      constant: -(Theme.messageListBottomInset + insetForCompose)
    )

    // Centered on the compose side controls' axis, the mirror of the avatar column.
    NSLayoutConstraint.activate([
      scrollToBottomButton.centerXAnchor.constraint(
        equalTo: scrollView.messageColumnGuide.trailingAnchor,
        constant: -ChatFloatingButtonMetrics.centerInset
      ),
      scrollToBottomBottomConstraint,
      scrollToBottomButton.widthAnchor.constraint(equalToConstant: ChatFloatingButtonMetrics.size),
      scrollToBottomButton.heightAnchor.constraint(equalToConstant: ChatFloatingButtonMetrics.size),
    ])

    view.addSubview(activityJumpButton)
    activityJumpBottomConstraint = activityJumpButton.bottomAnchor.constraint(
      equalTo: view.bottomAnchor,
      constant: activityJumpBottomConstant
    )
    view.addSubview(reactionJumpButton)
    reactionJumpBottomConstraint = reactionJumpButton.bottomAnchor.constraint(
      equalTo: view.bottomAnchor,
      constant: reactionJumpBottomConstant
    )
    NSLayoutConstraint.activate([
      activityJumpButton.centerXAnchor.constraint(equalTo: scrollToBottomButton.centerXAnchor),
      activityJumpBottomConstraint,
      activityJumpButton.widthAnchor.constraint(equalToConstant: ChatFloatingButtonMetrics.size),
      activityJumpButton.heightAnchor.constraint(equalToConstant: ChatFloatingButtonMetrics.size),
      reactionJumpButton.centerXAnchor.constraint(equalTo: scrollToBottomButton.centerXAnchor),
      reactionJumpBottomConstraint,
      reactionJumpButton.widthAnchor.constraint(equalToConstant: ChatFloatingButtonMetrics.size),
      reactionJumpButton.heightAnchor.constraint(equalToConstant: ChatFloatingButtonMetrics.size),
    ])
    startActivityNavigator()
  }

  // MARK: - Unread mentions and replies

  /// Buttons stack from the bottom: scroll-to-bottom, then @, then ♥. Hidden ones take no slot.
  private func jumpButtonBottomConstant(slot: Int) -> CGFloat {
    -(Theme.messageListBottomInset + insetForCompose)
      - CGFloat(slot) * (ChatFloatingButtonMetrics.size + ChatFloatingButtonMetrics.spacing)
  }

  private var activityJumpBottomConstant: CGFloat {
    jumpButtonBottomConstant(slot: isScrollToBottomButtonShown ? 1 : 0)
  }

  private var reactionJumpBottomConstant: CGFloat {
    jumpButtonBottomConstant(slot: (isScrollToBottomButtonShown ? 1 : 0) + (activityJumpButton.count > 0 ? 1 : 0))
  }

  private func updateActivityJumpPosition(animate: Bool) {
    guard let activityJumpBottomConstraint, let reactionJumpBottomConstraint else { return }
    if animate {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        context.allowsImplicitAnimation = true
        activityJumpBottomConstraint.animator().constant = activityJumpBottomConstant
        reactionJumpBottomConstraint.animator().constant = reactionJumpBottomConstant
      }
    } else {
      activityJumpBottomConstraint.constant = activityJumpBottomConstant
      reactionJumpBottomConstraint.constant = reactionJumpBottomConstant
    }
  }

  private func setScrollToBottomButtonShown(_ shown: Bool) {
    scrollToBottomButton.setVisibility(shown)
    guard isScrollToBottomButtonShown != shown else { return }
    isScrollToBottomButtonShown = shown
    updateActivityJumpPosition(animate: true)
  }

  private func startActivityNavigator() {
    guard activityNavigator == nil, chatId > 0 else { return }
    let navigator = ChatActivityNavigator(peerId: peerId, chatId: chatId)
    navigator.onChange = { [weak self] state in
      self?.applyActivityState(state, animate: true)
    }
    activityNavigator = navigator
    navigator.start()
    applyActivityState(navigator.state, animate: false)
  }

  private func applyActivityState(_ state: ChatActivityNavigator.State, animate: Bool) {
    // Marking the chat unread supersedes what this list read before.
    if state.unreadMark { unreadCountReadFrontier = 0 }
    updateScrollToBottomCount()
    guard activityJumpButton.count != state.mentionsCount || reactionJumpButton.count != state.reactionsCount
    else { return }
    activityJumpButton.setCount(state.mentionsCount)
    reactionJumpButton.setCount(state.reactionsCount)
    updateActivityJumpPosition(animate: animate)
  }

  private func jumpToNextReaction() {
    guard let navigator = activityNavigator else { return }
    Task { @MainActor [weak self] in
      guard let messageId = await navigator.nextReactionMessageId(), let self, !self.isDisposed else { return }
      self.scrollToMsgAndHighlight(ScrollToMessageRequest(messageId: messageId, reason: .mention))
    }
  }

  private func jumpToNextActivity() {
    guard let navigator = activityNavigator else { return }
    Task { @MainActor [weak self] in
      guard let messageId = await navigator.nextMessageId(), let self, !self.isDisposed else { return }
      self.scrollToMsgAndHighlight(ScrollToMessageRequest(messageId: messageId, reason: .mention))
    }
  }

  /// Reports on-screen messages so unseen mentions and replies are marked read after a short dwell.
  private func reportVisibleActivity() {
    guard let activityNavigator else { return }
    guard AppActivityMonitor.shared.isActive,
          isViewLoaded,
          let window = view.window,
          window.isVisible,
          !view.isHiddenOrHasHiddenAncestor,
          !needsInitialScroll,
          // The list is hidden over the latest page while history around the unread line loads.
          unreadFetchBoundary == nil
    else {
      activityNavigator.clearVisible()
      return
    }
    activityNavigator.noteVisible(messageIds: visibleMessageIDs())
  }

  private func scheduleAvatarOverlaySync(force: Bool = true, animate: Bool = false) {
    guard usesAvatarOverlay, isViewLoaded, !isDisposed else { return }

    if avatarOverlaySyncInProgress {
      avatarOverlaySyncPending = true
      return
    }

    avatarOverlaySyncInProgress = true
    repeat {
      let shouldForce = force || avatarOverlaySyncPending
      avatarOverlaySyncPending = false
      syncAvatarOverlay(force: shouldForce, animate: animate)
    } while avatarOverlaySyncPending && !isDisposed
    avatarOverlaySyncInProgress = false
  }

  private func syncAvatarOverlayAfterTableLayout(force: Bool = true, animate: Bool = false) {
    guard usesAvatarOverlay, isViewLoaded, !isDisposed else { return }

    tableView.layoutSubtreeIfNeeded()
    scheduleAvatarOverlaySync(force: force, animate: animate)
  }

  private func installAvatarOverlayIfNeeded(raise: Bool = false) {
    guard usesAvatarOverlay else { return }

    if avatarOverlayView.superview === tableView {
      let frame = tableView.bounds
      if avatarOverlayView.frame != frame {
        avatarOverlayView.frame = frame
      }

      guard raise, tableView.subviews.last !== avatarOverlayView else { return }
      tableView.addSubview(avatarOverlayView, positioned: .above, relativeTo: nil)
      return
    }

    if avatarOverlayView.superview != nil {
      avatarOverlayView.removeFromSuperview()
    }
    avatarOverlayView.frame = tableView.bounds
    avatarOverlayView.autoresizingMask = [.width, .height]
    tableView.addSubview(avatarOverlayView, positioned: .above, relativeTo: nil)
  }

  private func syncAvatarOverlay(force: Bool, animate: Bool) {
    guard usesAvatarOverlay, isViewLoaded, !isDisposed else { return }

    let visibleRect = tableView.visibleRect
    let viewportRect = scrollView.effectiveVisibleRect()
    let comparableVisibleRect = viewportRect
    let range = tableView.rows(in: visibleRect)
    guard range.location != NSNotFound, range.length > 0 else {
      lastAvatarOverlayVisibleRange = nil
      lastAvatarOverlayVisibleRect = nil
      if tableView.numberOfRows == 0 {
        avatarOverlayView.clearAvatars()
      }
      return
    }
    if !force,
       !avatarOverlayNeedsRaise,
       avatarOverlayView.superview === tableView,
       let lastAvatarOverlayVisibleRange,
       let lastAvatarOverlayVisibleRect,
       NSEqualRanges(lastAvatarOverlayVisibleRange, range),
       lastAvatarOverlayVisibleRect == comparableVisibleRect
    {
      return
    }
    lastAvatarOverlayVisibleRange = range
    lastAvatarOverlayVisibleRect = comparableVisibleRect

    installAvatarOverlayIfNeeded(raise: avatarOverlayNeedsRaise)
    avatarOverlayNeedsRaise = false
    guard avatarOverlayView.superview != nil else { return }
    let viewportFrame = avatarOverlayView.convert(viewportRect, from: tableView)

    let start = max(range.location, 0)
    let end = min(range.location + range.length, tableView.numberOfRows)
    guard start < end else {
      if tableView.numberOfRows == 0 {
        avatarOverlayView.clearAvatars()
      }
      return
    }

    var items: [MessageAvatarOverlayItem] = []
    var processedAvatarStableIds = Set<Int64>()
    items.reserveCapacity(end - start)

    #if DEBUG
    let startedAt = Date()
    let signpostID = OSSignpostID(log: Self.signpostLog)
    os_signpost(
      .begin,
      log: Self.signpostLog,
      name: "MacAvatarOverlaySync",
      signpostID: signpostID,
      "%{public}s",
      "force=\(force) animate=\(animate) rows=\(end - start)"
    )
    #endif

    var row = start
    while row < end {
      guard let group = avatarOverlayGroup(forVisibleRow: row) else {
        row += 1
        continue
      }
      defer {
        row = rowAfterAvatarGroup(currentRow: row, groupRange: group.range, visibleEnd: end)
      }

      let ownerIndex = avatarOwnerIndex(in: group.range)
      let ownerStableId = messages[ownerIndex].id
      guard processedAvatarStableIds.insert(ownerStableId).inserted else { continue }

      guard let item = avatarOverlayItem(
        groupRange: group.range,
        visibleStart: start,
        visibleEnd: end,
        viewportFrame: viewportFrame
      ) else {
        continue
      }
      items.append(item)
    }

    let stats = avatarOverlayView.sync(
      items: items,
      animate: animate
    )

    #if DEBUG
    os_signpost(
      .end,
      log: Self.signpostLog,
      name: "MacAvatarOverlaySync",
      signpostID: signpostID,
      "%{public}s",
      "rows=\(end - start) items=\(items.count) active_before=\(stats.active) created=\(stats.created) reused=\(stats.reused) removed=\(stats.removed) recycled=\(stats.recycled) frames=\(stats.frameUpdates) animated_frames=\(stats.animatedFrameUpdates) duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: startedAt))"
    )
    #endif
  }

  private func avatarOverlayGroup(forVisibleRow row: Int) -> (messageIndex: Int, range: ClosedRange<Int>)? {
    guard usesAvatarOverlay(forRow: row) else { return nil }
    guard let stableId = messageStableId(forRow: row) else { return nil }
    guard let messageIndex = chatRows.messageIndex(forStableMessageId: stableId) else { return nil }
    guard messages.indices.contains(messageIndex) else { return nil }

    let message = messages[messageIndex]
    guard showsAvatarOverlay(for: message) else { return nil }

    return (messageIndex, avatarGroupRange(containing: messageIndex))
  }

  private func rowAfterAvatarGroup(
    currentRow: Int,
    groupRange: ClosedRange<Int>,
    visibleEnd: Int
  ) -> Int {
    guard let lastRow = chatRows.rowIndex(forMessageStableId: messages[groupRange.upperBound].id) else {
      return currentRow + 1
    }
    return max(currentRow + 1, min(lastRow + 1, visibleEnd))
  }

  private func avatarOverlayItem(
    groupRange: ClosedRange<Int>,
    visibleStart: Int,
    visibleEnd: Int,
    viewportFrame: CGRect
  ) -> MessageAvatarOverlayItem? {
    guard let firstRow = chatRows.rowIndex(forMessageStableId: messages[groupRange.lowerBound].id),
          let lastRow = chatRows.rowIndex(forMessageStableId: messages[groupRange.upperBound].id)
    else {
      return nil
    }

    let ownerMessage = messages[avatarOwnerIndex(in: groupRange)]
    let limitFrame = avatarOverlayView.convert(
      avatarStickyLimitFrame(groupRange: groupRange, firstRow: firstRow, lastRow: lastRow),
      from: tableView
    )
    let sticky = MessageAvatarOverlaySticky(
      mode: avatarOverlayStickyMode,
      viewportFrame: viewportFrame,
      limitFrame: limitFrame,
      viewportEdgeInset: avatarOverlayStickyViewportInset
    )

    let anchorRow = avatarAnchorRow(firstRow: firstRow, lastRow: lastRow)
    if anchorRow >= visibleStart,
       anchorRow < visibleEnd,
       let cell = tableView.view(atColumn: 0, row: anchorRow, makeIfNecessary: false) as? MessageTableCell,
       var item = cell.avatarOverlayItem(in: avatarOverlayView)
    {
      item.sticky = sticky
      return item
    }

    return syntheticAvatarOverlayItem(
      for: ownerMessage,
      firstRow: firstRow,
      lastRow: lastRow,
      sticky: sticky
    )
  }

  private func avatarGroupRange(containing index: Int) -> ClosedRange<Int> {
    var start = index
    while start > messages.startIndex, canGroup(messages[start - 1], messages[start]) {
      start -= 1
    }

    var end = index
    while end < messages.index(before: messages.endIndex), canGroup(messages[end], messages[end + 1]) {
      end += 1
    }

    return start ... end
  }

  private func avatarOwnerIndex(in groupRange: ClosedRange<Int>) -> Int {
    switch avatarOverlayStickyMode {
      case .bottom:
        groupRange.upperBound
      case .top:
        groupRange.lowerBound
    }
  }

  private func showsAvatarOverlay(for message: FullMessage) -> Bool {
    switch messageRenderStyle {
      case .bubble:
        chat?.type != .privateChat && message.message.out != true
      case .minimal:
        true
    }
  }

  private func canGroup(_ earlier: FullMessage, _ later: FullMessage) -> Bool {
    guard !earlier.message.isServiceMessage, !later.message.isServiceMessage else { return false }
    guard earlier.message.fromId == later.message.fromId else { return false }

    let gapSeconds = later.message.date.timeIntervalSince(earlier.message.date)
    guard gapSeconds <= 300 else { return false }

    return avatarOverlayGroupCalendar.isDate(earlier.message.date, inSameDayAs: later.message.date)
  }

  private func avatarStickyLimitFrame(
    groupRange: ClosedRange<Int>,
    firstRow: Int,
    lastRow: Int
  ) -> CGRect {
    var frame = avatarGroupFrame(firstRow: firstRow, lastRow: lastRow)

    switch avatarOverlayStickyMode {
      case .bottom:
        let startOffset = avatarStickyStartOffset(groupRange: groupRange)
        frame.origin.y += startOffset
        frame.size.height = max(0, frame.height - startOffset)

      case .top:
        break
    }

    return frame
  }

  private func avatarGroupFrame(firstRow: Int, lastRow: Int) -> CGRect {
    let firstFrame = tableView.rect(ofRow: firstRow)
    let lastFrame = tableView.rect(ofRow: lastRow)
    let minY = min(firstFrame.minY, lastFrame.minY)
    let maxY = max(firstFrame.maxY, lastFrame.maxY)
    return CGRect(x: 0, y: minY, width: tableView.bounds.width, height: max(0, maxY - minY))
  }

  private func avatarStickyStartOffset(groupRange: ClosedRange<Int>) -> CGFloat {
    switch (messageRenderStyle, avatarOverlayStickyMode) {
      case (.bubble, .bottom):
        let firstMessage = messages[groupRange.lowerBound]
        let nameHeight = avatarGroupShowsName(for: firstMessage) ? Theme.messageNameLabelHeight : 0
        return bubbleGroupStartInset + nameHeight

      case (.bubble, .top), (.minimal, _):
        return 0
    }
  }

  private var bubbleGroupStartInset: CGFloat {
    Theme.messageGroupSpacing + Theme.messageOuterVerticalPadding
  }

  private func avatarGroupShowsName(for message: FullMessage) -> Bool {
    chat?.type != .privateChat && message.message.out != true
  }

  private func syntheticAvatarOverlayItem(
    for message: FullMessage,
    firstRow: Int,
    lastRow: Int,
    sticky: MessageAvatarOverlaySticky
  ) -> MessageAvatarOverlayItem? {
    let anchorRow = avatarAnchorRow(firstRow: firstRow, lastRow: lastRow)
    guard let frame = syntheticAvatarFrame(forRow: anchorRow) else { return nil }

    return MessageAvatarOverlayItem(
      stableId: message.id,
      userInfo: avatarUserInfo(for: message),
      frame: frame,
      sticky: sticky
    ) { [weak self] in
      guard let self else { return }
      guard let user = message.senderInfo?.user else { return }
      Task { @MainActor in
        self.dependencies.requestOpenChat(peer: .user(id: user.id))
      }
    }
  }

  private func avatarUserInfo(for message: FullMessage) -> UserInfo {
    if let senderInfo = message.senderInfo {
      return senderInfo
    }

    if messageRenderStyle == .minimal,
       message.message.out == true,
       let currentUserInfo = dependencies.rootData?.currentUserInfo
    {
      return currentUserInfo
    }

    return .deleted
  }

  private func avatarAnchorRow(firstRow: Int, lastRow: Int) -> Int {
    switch avatarOverlayStickyMode {
      case .bottom:
        lastRow
      case .top:
        firstRow
    }
  }

  private func syntheticAvatarFrame(forRow row: Int) -> CGRect? {
    guard row >= 0, row < tableView.numberOfRows else { return nil }
    let rowFrame = tableView.rect(ofRow: row)

    let metrics = syntheticAvatarMetrics(rowFrame: rowFrame, row: row)
    let origin = avatarOverlayView.convert(metrics.origin, from: tableView)
    return CGRect(
      x: origin.x,
      y: origin.y,
      width: metrics.size.width,
      height: metrics.size.height
    )
  }

  private func syntheticAvatarMetrics(rowFrame: CGRect, row: Int) -> (origin: CGPoint, size: CGSize) {
    switch messageRenderStyle {
      case .bubble:
        let size = CGSize(width: Theme.messageAvatarSize, height: Theme.messageAvatarSize)
        return (
          origin: CGPoint(
            x: MessageSizeCalculator.bubbleAvatarLeadingInset,
            y: rowFrame.maxY - Theme.messageOuterVerticalPadding - size.height
          ),
          size: size
        )

      case .minimal:
        let size = CGSize(
          width: MessageSizeCalculator.minimalAvatarSize,
          height: MessageSizeCalculator.minimalAvatarSize
        )
        let groupSpacing = if isFirstMessage(at: row) {
          CGFloat(0)
        } else if startsAfterDaySeparator(row: row) {
          MessageSizeCalculator.minimalAfterDaySeparatorGroupSpacing
        } else {
          MessageSizeCalculator.minimalGroupSpacing
        }
        return (
          origin: CGPoint(
            x: MessageSizeCalculator.minimalContentLeadingInset,
            y: rowFrame.minY + Theme.messageOuterVerticalPadding + groupSpacing +
              MessageSizeCalculator.minimalNameAvatarOffset
          ),
          size: size
        )
    }
  }

  private var lastColumnWidthUpdate: CGFloat = 0

  var messageColumnGuide: NSLayoutGuide {
    scrollView.messageColumnGuide
  }

  func setTopOverlayHeight(_ height: CGFloat) {
    guard topOverlayHeight != height else { return }
    topOverlayHeight = height
    applyPinnedHeaderSuppression()
    updateScrollViewInsets()
  }

  /// The pinned header shows itself when it has a pin; a top overlay keeps it hidden.
  private func applyPinnedHeaderSuppression() {
    if topOverlayHeight > 0 {
      pinnedHeaderView.isHidden = true
    } else if pinnedHeaderHeight > 0 {
      pinnedHeaderView.isHidden = false
    }
  }

  func setMaximumContentWidth(_ width: CGFloat?) {
    guard scrollView.maximumContentWidth != width else { return }
    // The message width cap also changes when toggling in a narrow window.
    lastKnownWidth = 0
    scrollView.maximumContentWidth = width
    view.needsLayout = true
  }

  private func updateColumnWidth(commit: Bool = false) {
    let newWidth = scrollView.messageContentWidth
    #if DEBUG
    log.trace("Updating column width \(newWidth)")
    #endif
    if abs(newWidth - lastColumnWidthUpdate) > 0.5 {
      let column = tableView.tableColumns.first

      if commit {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
      }

      column?.width = newWidth

      if commit {
        CATransaction.commit()
      }

      lastColumnWidthUpdate = newWidth
    }
  }

  private func updateColumnWidthAndCommit() {
    updateColumnWidth(commit: true)
  }

  /// The single width source for message size calculation.
  ///
  /// AppKit can ask `heightOfRow` before the table column has its final width. Measuring minimal messages against
  /// those tiny provisional widths can create huge wrapped text heights, so callers should use this helper and skip
  /// sizing until it returns a valid width.
  private func measurementWidth() -> CGFloat? {
    measurementWidth(using: tableView, renderStyle: messageRenderStyle)
  }

  private func measurementWidth(using tableView: NSTableView, renderStyle: MessageRenderStyle) -> CGFloat? {
    let width = rawMeasurementWidth(using: tableView)
    if isValidMeasurementWidth(width, renderStyle: renderStyle) {
      lastValidMeasurementWidth = width
      return width
    }

    if isValidMeasurementWidth(lastValidMeasurementWidth, renderStyle: renderStyle) {
      return lastValidMeasurementWidth
    }

    return nil
  }

  private func rawMeasurementWidth(using tableView: NSTableView) -> CGFloat {
    if let scroll = tableView.enclosingScrollView as? MessageListScrollView,
       scroll.maximumContentWidth != nil
    {
      let selectionInset = showsForwardSelection ? MessageTableCell.forwardSelectionInset : 0
      return ceil(scroll.messageContentWidth) - selectionInset
    }
    let viewWidth = isViewLoaded ? view.bounds.width : 0
    let widths: [CGFloat] = [
      tableView.bounds.width,
      // Do not touch `self.scrollView` here: AppKit can ask row heights while `scrollView` is still being built.
      tableView.enclosingScrollView?.contentSize.width ?? 0,
      tableView.tableColumns.first?.width ?? 0.0,
      viewWidth,
    ]
    let selectionInset = showsForwardSelection ? MessageTableCell.forwardSelectionInset : 0
    return ceil(widths.max() ?? 0) - selectionInset
  }

  private func isValidMeasurementWidth(_ width: CGFloat, renderStyle: MessageRenderStyle) -> Bool {
    guard width > 0 else { return false }
    let availableWidth = sizeCalculator.getAvailableWidth(tableWidth: width, renderStyle: renderStyle)
    return availableWidth >= minimumAvailableMeasurementWidth
  }

  private func fallbackMeasurementWidth(renderStyle: MessageRenderStyle) -> CGFloat {
    switch renderStyle {
      case .bubble:
        MessageSizeCalculator.maxMessageWidth + Theme.messageAvatarSize + Theme.messageHorizontalStackSpacing +
          Theme.messageSidePadding + MessageSizeCalculator.safeAreaWidth
      case .minimal:
        MessageSizeCalculator.minimalMaxMessageWidth + MessageSizeCalculator.minimalContentLeadingInset +
          Theme.messageHorizontalStackSpacing + MessageSizeCalculator.minimalAvatarSize +
          minimumAvailableMeasurementWidth
    }
  }

  private func scrollToNewestAvailable(animated: Bool) {
    releaseReadingHold()
    // Returning to latest forgets the reading place; the place being left is not saved again
    // while the latest messages load or the list scrolls down to them.
    ChatReadingPlaceStore.shared.clear(for: peerId)
    readingPlaceCaptureBlocked = true
    guard !chatRows.historyCoverage.isAtCertifiedLiveEnd else {
      scrollToBottom(animated: animated)
      return
    }

    targetScrollRevision &+= 1
    let account = try? Auth.shared.handle.beginAccountMutation()
    targetScrollTask?.cancel()
    remoteNewerTask?.cancel()
    remoteNewerTask = nil
    targetScrollTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        guard let account else { throw CancellationError() }
        guard try await applyLatestWindow(animated: animated) else { return }
        var transaction = GetChatHistoryTransaction(peer: peerId, mode: .historyModeLatest)
        transaction.type = .ephemeral()
        _ = try await Api.realtime.send(transaction, expectedAccount: account)
        try Task.checkCancellation()
        _ = try await applyLatestWindow(animated: animated)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, !isDisposed else { return }
        ToastCenter.shared.showError("Could not load latest history")
      }
    }
  }

  private func applyLatestWindow(animated: Bool) async throws -> Bool {
    guard try await chatRows.loadLatestWindow(), !isDisposed else { return false }
    let anchors = Task.isCancelled ? viewport.anchors() : []
    rebuildRowItems()
    clearHoveredMessage()
    tableView.reloadData()
    pruneMessageSelection()
    scheduleMessageHoverRefresh()
    tableView.layoutSubtreeIfNeeded()
    if Task.isCancelled {
      if let anchor = anchors.first(where: { viewport.index(of: $0) != nil }) {
        viewport.restore(anchor)
      }
      return false
    }
    scrollToBottom(animated: animated)
    return true
  }

  private func scrollToBottom(animated: Bool) {
    guard chatRows.rowCount > 0 else { return }
    scrolledAwayFromBottom = false
    releaseReadingHold()
    #if DEBUG
    log.trace("Scrolling to bottom animated=\(animated)")
    #endif

    beginProgrammaticScroll()

    defer {
      endProgrammaticScroll()
    }

    if animated {
      // Causes clipping at the top
      NSAnimationContext.runAnimationGroup { [weak self] context in
        guard let self else { return }
        context.duration = debug_slowAnimation ? 1.5 : 0.2
        context.allowsImplicitAnimation = true

        tableView.scrollToBottomWithInset(cancel: false)
        //        tableView.scrollRowToVisible(lastRow)
      }
    } else {
      tableView.scrollToBottomWithInset(cancel: true)

//      CATransaction.begin()
//      CATransaction.setDisableActions(true)
//      tableView.scrollToBottomWithInset()
//      CATransaction.commit()

      // Test if this gives better performance than above solution
//        NSAnimationContext.runAnimationGroup { context in
//          context.duration = 0
//          context.allowsImplicitAnimation = false
//          tableView.scrollToBottomWithInset()
//        }
      // }
    }

    scheduleAvatarOverlaySync()
  }

  private func setupScrollObserver() {
    // Use direct observation for immediate response
    scrollView.shouldPinBottomOnHeightChange = { [weak self] in
      guard let self, !needsInitialScroll, !suppressResizeScrollMaintenance else { return false }
      return shouldKeepBottomPinned
    }
    scrollView.contentView.postsFrameChangedNotifications = true
    scrollView.contentView.postsBoundsChangedNotifications = true

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollViewFrameChanged),
      name: NSView.frameDidChangeNotification,
      object: scrollView.contentView
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollViewBoundsChanged),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(userDidScroll),
      name: NSScrollView.didLiveScrollNotification,
      object: scrollView
    )

    // Add scroll wheel notification
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollWheelBegan),
      name: NSScrollView.willStartLiveScrollNotification,
      object: scrollView
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollWheelEnded),
      name: NSScrollView.didEndLiveScrollNotification,
      object: scrollView
    )
  }

  @objc private func richBlockLayoutStateDidChange(_ notification: Notification) {
    guard !isDisposed,
          AppSettings.shared.richContentRendererEnabled,
          let stableID = notification.userInfo?["messageStableID"] as? Int64,
          stableID != 0
    else { return }

    let rows = chatRows.rowIndexes(forMessageStableId: stableID)
    guard let lastRow = rows.last, lastRow < tableView.numberOfRows else { return }

    let pinned = shouldKeepBottomPinned
    let anchor = pinned ? nil : viewport.anchors().first
    NSAnimationContext.runAnimationGroup { [weak self] context in
      guard let self else { return }
      // A moving header can leave NSButton's tracking rect between mouse-down
      // and mouse-up when the next disclosure is clicked quickly.
      let isDisclosureToggle = notification.object is RichBlockLocalStateStore
      let movesAnchor = anchor?.hasChangesAbove(rows) == true
      let animate = !isDisclosureToggle && !movesAnchor && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      context.duration = animate ? 0.16 : 0
      MessageGestureTrace
        .debug("MessageList.richLayout rows=\(rows) disclosure=\(isDisclosureToggle) duration=\(context.duration)")
      // Do not wrap a reload plus height invalidation in begin/endUpdates.
      // AppKit applies the height delta twice to the reloaded cell, leaving
      // its hit-test bounds smaller or larger than the visible message row.
      tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
      tableView.noteHeightOfRows(withIndexesChanged: rows)
      restoreAfterRemeasure(pinned: pinned, anchor: anchor)
    } completionHandler: { [weak self] in
      self?.maintainReadingHoldIfNeeded()
      self?.syncAvatarOverlayAfterTableLayout()
      self?.refreshMessageHoverAfterGeometryChange()
    }
  }

  private var liveResizeObserver: NSObjectProtocol?

  private func setupLiveResizeObserver() {
    removeLiveResizeObserver()
    guard let window = view.window else { return }

    liveResizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didEndLiveResizeNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      self?.liveResizeEnded()
    }
  }

  private func removeLiveResizeObserver() {
    guard let observer = liveResizeObserver else { return }
    NotificationCenter.default.removeObserver(observer)
    liveResizeObserver = nil
  }

  private func setupMessageHoverTracking() {
    guard messageRenderStyle == .minimal, messageHoverTrackingArea == nil else { return }

    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    tableView.addTrackingArea(trackingArea)
    messageHoverTrackingArea = trackingArea
  }

  private func removeMessageHoverTracking() {
    if let messageHoverTrackingArea {
      tableView.removeTrackingArea(messageHoverTrackingArea)
      self.messageHoverTrackingArea = nil
    }
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    updateHoveredMessage(from: event)
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    updateHoveredMessage(from: event)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    guard !isQuickActionsPresentationOpen else { return }
    clearHoveredMessage()
  }

  private func refreshMessageHoverAfterGeometryChange() {
    guard messageRenderStyle == .minimal else { return }

    guard scrollState == .idle, !isUserScrolling, !isProgrammaticScroll else {
      clearHoveredMessage()
      return
    }

    scheduleMessageHoverRefresh()
  }

  private func scheduleMessageHoverRefresh() {
    guard messageRenderStyle == .minimal, !isDisposed, !messageHoverRefreshScheduled else { return }

    messageHoverRefreshScheduled = true
    DispatchQueue.main.async(qos: .userInteractive) { [weak self] in
      guard let self else { return }
      messageHoverRefreshScheduled = false
      guard !isDisposed else { return }
      updateHoveredMessageFromCurrentMouseLocation(force: true)
    }
  }

  private func updateHoveredMessage(from event: NSEvent) {
    guard messageRenderStyle == .minimal else { return }
    guard scrollState == .idle, !isUserScrolling, !isProgrammaticScroll else {
      clearHoveredMessage()
      return
    }

    let point = tableView.convert(event.locationInWindow, from: nil)
    updateHoveredMessage(at: point)
  }

  private func updateHoveredMessageFromCurrentMouseLocation(force: Bool = false) {
    guard messageRenderStyle == .minimal else { return }
    guard scrollState == .idle, !isUserScrolling, !isProgrammaticScroll else {
      clearHoveredMessage()
      return
    }
    guard let window = tableView.window else {
      clearHoveredMessage()
      return
    }

    let point = tableView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    updateHoveredMessage(at: point, force: force)
  }

  private func updateHoveredMessage(at point: NSPoint, force: Bool = false) {
    guard !isQuickActionsPresentationOpen else { return }
    guard let target = messageHoverTarget(at: point) else {
      setHoveredMessage(stableId: nil, cell: nil, force: force)
      return
    }

    setHoveredMessage(stableId: target.stableId, cell: target.cell, force: force)
  }

  private func messageHoverTarget(at point: NSPoint) -> (stableId: Int64, cell: MessageTableCell)? {
    guard tableView.visibleRect.contains(point) else { return nil }

    // The capsule overlaps the preceding row. Keep ownership with its message while
    // crossing that edge instead of letting NSTableView switch to the row underneath.
    if let messageQuickActionsView, !messageQuickActionsView.isHidden,
       messageQuickActionsView.frame.contains(point),
       let stableId = hoveredMessageStableId, let cell = hoveredMessageCell,
       cell.quickActionsMessageView?.fullMessage.message.stableId == stableId,
       messageStableId(forRow: tableView.row(for: cell)) == stableId
    {
      return (stableId, cell)
    }

    let row = tableView.row(at: point)
    guard row >= 0, row < tableView.numberOfRows else { return nil }
    guard let stableId = messageStableId(forRow: row) else { return nil }
    guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCell else {
      return nil
    }
    guard cell.containsMessageHoverPoint(point, from: tableView) else { return nil }

    return (stableId, cell)
  }

  private func setHoveredMessage(stableId: Int64?, cell: MessageTableCell?, force: Bool = false) {
    guard force || hoveredMessageStableId != stableId || hoveredMessageCell !== cell else { return }

    let previousCell = hoveredMessageCell
    hoveredMessageStableId = stableId
    hoveredMessageCell = cell

    if previousCell !== cell {
      hideMessageQuickActions()
      previousCell?.setMessageHoverState(false)
    }
    cell?.setMessageHoverState(true)
    updateMessageQuickActions()
  }

  private func clearHoveredMessage() {
    hideMessageQuickActions()
    setHoveredMessage(stableId: nil, cell: nil)
  }

  private func hideMessageQuickActions() {
    let reactionOverlay = quickActionsReactionOverlay
    quickActionsReactionOverlay = nil
    reactionOverlay?.close()
    messageQuickActionsView?.setActiveAction(nil)
    messageQuickActionsView?.hideTooltips()
    messageQuickActionsView?.isHidden = true
    messageQuickActionsView?.onAction = nil
  }

  private func updateMessageQuickActions() {
    guard messageRenderStyle == .minimal,
          !isDisposed, !messageSelection.isActive, scrollState == .idle, !isUserScrolling, !isProgrammaticScroll,
          let cell = hoveredMessageCell, let stableId = hoveredMessageStableId,
          let renderer = cell.quickActionsMessageView,
          renderer.fullMessage.message.stableId == stableId,
          renderer.window != nil
    else {
      hideMessageQuickActions()
      return
    }

    let anchor = renderer.quickActionsAnchorRect(in: tableView)
    let viewport = scrollView.effectiveVisibleRect().intersection(tableView.visibleRect)
    let size = MessageQuickActionsView.preferredSize
    guard anchor.intersects(viewport), viewport.width >= size.width + 16,
          viewport.height >= size.height + 8
    else {
      hideMessageQuickActions()
      return
    }

    let capsule: MessageQuickActionsView
    if let existing = messageQuickActionsView {
      capsule = existing
    } else {
      capsule = MessageQuickActionsView(frame: NSRect(origin: .zero, size: size))
      messageQuickActionsView = capsule
    }

    capsule.setActionsEnabled(canReply: renderer.quickActionsCanReply, canReact: renderer.quickActionsCanReact)
    capsule.frame = NSRect(
      x: min(max(anchor.maxX - size.width - 8, viewport.minX + 8), viewport.maxX - size.width - 8),
      y: min(max(anchor.minY - size.height / 2, viewport.minY + 4), viewport.maxY - size.height - 4),
      width: size.width,
      height: size.height
    )
    if tableView.subviews.last !== capsule {
      tableView.addSubview(capsule, positioned: .above, relativeTo: nil)
    }
    capsule.isHidden = false
    capsule.refreshHoverState()
    capsule.onAction = { [weak self, weak cell, weak capsule] action, button in
      guard let self, let cell, let capsule, !isDisposed, !isProgrammaticScroll,
            !messageSelection.isActive, hoveredMessageCell === cell,
            let renderer = cell.quickActionsMessageView,
            renderer.fullMessage.message.stableId == stableId,
            messageStableId(forRow: tableView.row(for: cell)) == stableId else { return }
      if action == .reaction, let overlay = quickActionsReactionOverlay, overlay.isVisible {
        overlay.close()
        return
      }
      // Protect hover during presentation as well as the synchronous menu loop.
      isQuickActionsMenuOpen = action == .more || action == .reaction
      quickActionsReactionOverlay?.close()
      capsule.setActiveAction(isQuickActionsMenuOpen ? action : nil)
      defer {
        isQuickActionsMenuOpen = false
        capsule.setActiveAction(quickActionsReactionOverlay?.isVisible == true ? .reaction : nil)
        scheduleMessageHoverRefresh()
      }
      if let overlay = renderer.performQuickAction(action, from: button, capsule: capsule) {
        quickActionsReactionOverlay = overlay
        overlay.toggleButton = button
        overlay.onClose = { [weak self, weak overlay] in
          guard let self, quickActionsReactionOverlay === overlay else { return }
          quickActionsReactionOverlay = nil
          messageQuickActionsView?.setActiveAction(nil)
          scheduleMessageHoverRefresh()
        }
      }
    }
  }

  private func shouldHoverMessageCell(_ cell: MessageTableCell, stableId: Int64) -> Bool {
    guard messageRenderStyle == .minimal, hoveredMessageStableId == stableId else { return false }
    guard let window = tableView.window else { return false }

    let point = tableView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    return cell.containsMessageHoverPoint(point, from: tableView)
  }

  private var scrollState: MessageListScrollState = .idle {
    didSet {
      NotificationCenter.default.post(
        name: .messageListScrollStateDidChange,
        object: scrollView,
        userInfo: ["state": scrollState]
      )
    }
  }

  @objc private func userDidScroll() {
    // A discrete wheel can deliver just this notification. Its new position still owns
    // the viewport, even if a publication arrives before the next wheel tick.
    let unbracketed = !isUserScrolling
    if unbracketed { scrollWheelBegan() }
    let originY = scrollView.contentView.bounds.minY
    if viewport.distanceFromBottom <= Self.exactBottomTolerance {
      scrolledAwayFromBottom = false
    } else if originY == clipOriginY, originY != clipOriginBeforeLastMoveY {
      // AppKit posts this right after its own clip move, so the last move is the user's.
      // Rows arriving below grow the distance without moving the origin, so they can't detach.
      scrolledAwayFromBottom = originY < clipOriginBeforeLastMoveY
    } else if unbracketed {
      scrolledAwayFromBottom = true
    }
    if isAtBottom != isWithinFollowZone {
      handleBoundsChange(afterUserScroll: true)
    }
    if unbracketed { scrollWheelEnded() }
  }

  @objc private func scrollWheelBegan() {
    log.trace("scroll wheel began")
    isUserScrolling = true
    // User input supersedes both an in-flight fetch and an animated jump. Advance the
    // revision first: stopping the animation runs its completion at once, and that checks it.
    targetScrollRevision &+= 1
    targetScrollTask?.cancel()
    if needsInitialScroll, didQueueInitialFinalize {
      needsInitialScroll = false
      initialTargetMessageId = nil
      initialReadingPlace = nil
    }
    if isProgrammaticScroll {
      // A zero-length animation of the same property replaces the running one where it is.
      let clipView = scrollView.contentView
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0
        clipView.animator().setBoundsOrigin(clipView.bounds.origin)
      }
      endProgrammaticScroll()
    }
    releaseReadingHold()
    readingPlaceCaptureBlocked = false
    clearReplyThreadSourceAnchor()
    pendingArrivalMessageID = nil
    scrollState = .scrolling
    clearHoveredMessage()
  }

  @objc private func scrollWheelEnded() {
    log.trace("scroll wheel ended")
    isUserScrolling = false
    scrollState = .idle
    // A discrete wheel tick can end before the first throttled bounds notification.
    handleBoundsChange(afterUserScroll: true)

    DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
      self?.captureReadingPlace()
      self?.updateUnreadIfNeeded()
      self?.scheduleMediaWarmupForVisibleAndNearby(reason: "scroll_idle")
      self?.scheduleMessageHoverRefresh()
    }
  }

  /// Recalculate heights for all items once resize has ended
  @objc private func liveResizeEnded() {
    guard feature_updatesHeightsOnLiveResizeEnd else { return }

//    precalculateHeightsInBackground()
//
//    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
//      // Recalculate all height when user is done resizing
//      self?.recalculateHeightsOnWidthChange(buffer: 400)
//    }
    fullWidthAsyncCalc()
  }

  /// Precalcs width in bg and does full recalc, only call in special cases, not super performant for realtime call
  private func fullWidthAsyncCalc() {
    precalculateHeightsInBackground()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      // Recalculate all height when user is done resizing
      self?.recalculateHeightsOnWidthChange(buffer: 400)
    }
  }

  /// True while we're changing scroll position programmatically
  private var isProgrammaticScroll = false

  private func beginProgrammaticScroll() {
    isProgrammaticScroll = true
    clearHoveredMessage()
  }

  private func endProgrammaticScroll() {
    isProgrammaticScroll = false
    scheduleMessageHoverRefresh()
  }

  /// True when user is scrolling via trackpad or mouse wheel
  private var isUserScrolling = false

  /// Distance from latest at which a reader scrolling back down can resume following.
  private static let bottomFollowZone: CGFloat = 44
  /// Only a list resting at the bottom is pinned through geometry changes. AppKit snaps the
  /// scroll limit to the pixel grid, so this allows a point.
  private static let exactBottomTolerance: CGFloat = 1

  /// Last state reported to the history model and scroll button.
  private var isAtBottom = true {
    didSet {
      chatRows.setAtBottom(isAtBottom)
    }
  }

  private var scrolledAwayFromBottom = false
  /// Clip origin after and before its latest move. Programmatic restores update these too, so a
  /// live-scroll notification compares only against the user's own movement.
  private var clipOriginY: CGFloat = 0
  private var clipOriginBeforeLastMoveY: CGFloat = 0

  private func noteClipOriginChange() {
    let originY = scrollView.contentView.bounds.minY
    guard originY != clipOriginY else { return }
    clipOriginBeforeLastMoveY = clipOriginY
    clipOriginY = originY
  }

  /// The 44-point follow zone lets a reader returning towards latest reattach. A wheel
  /// tick away from latest detaches immediately, including between discrete mouse ticks.
  private var isWithinFollowZone: Bool {
    let distance = viewport.distanceFromBottom
    return distance <= Self.exactBottomTolerance || (!scrolledAwayFromBottom && distance <= Self.bottomFollowZone)
  }

  private var canFollowBottom: Bool {
    !isUserScrolling && !isProgrammaticScroll && readingHold == nil &&
      (replyThreadSourceAnchor == nil || replyThreadSourceKeepsBottom)
  }

  private var shouldKeepBottomPinned: Bool {
    canFollowBottom && viewport.distanceFromBottom <= Self.exactBottomTolerance
  }

  /// The highest incoming message this list asked to read; see `ChatUnreadBadgeCount`.
  private var unreadCountReadFrontier: Int64 = 0

  // Publications can overlap while AppKit finishes their animations.
  private var tableUpdateCount = 0
  private var isPerformingUpdate: Bool { tableUpdateCount > 0 }

  private func endTableUpdate() {
    tableUpdateCount -= 1
    if !isPerformingUpdate {
      maintainReadingHoldIfNeeded()
      if let buffer = deferredWidthBuffer, !isDisposed {
        deferredWidthBuffer = nil
        recalculateHeightsOnWidthChange(buffer: buffer)
      }
    }
  }

  private let boundsThrottleID = UUID().uuidString

  @objc func scrollViewBoundsChanged(notification: Notification) {
    noteClipOriginChange()
    updateMessageViewColors()
    scheduleAvatarOverlaySync(force: false)
    refreshMessageHoverAfterGeometryChange()

    throttle(.milliseconds(32), identifier: boundsThrottleID, by: .mainActor, option: .default) { [
      weak self
    ] in
      self?.handleBoundsChange()
    }
  }

  func updateToolbarDebounced() {
    if usesToolbarBgView, !fadesToolbarBgView {
      updateToolbar()
    } else if isToolbarVisible == true {
      throttle(.milliseconds(100), identifier: "chat.updateToolbar", by: .mainActor, option: .default) { [
        weak self
      ] in
        self?.updateToolbar()
      }
    } else {
      // bring it back as fast as possible as it looks bad
      updateToolbar()
    }
  }

  private func handleBoundsChange(afterUserScroll: Bool = false) {
    guard !isDisposed else { return }
    let userMoved = isUserScrolling || afterUserScroll
    let scrollOffset = scrollView.contentView.bounds.origin
    let viewportSize = scrollView.contentView.bounds.size
    let contentSize = scrollView.documentView?.frame.size ?? .zero
    let maxScrollableHeight = contentSize.height - viewportSize.height
    let currentScrollOffset = scrollOffset.y

    updateToolbarDebounced()

    if needsInitialScroll {
      // reports inaccurate heights at this point
      return
    }

    reportVisibleActivity()

    // Measured from the bottom origin `scrollToBottomWithInset` scrolls to, which includes the
    // bottom inset under the composer. Negative while elastic scrolling past the bottom.
    let prevAtBottom = isAtBottom
    isAtBottom = isWithinFollowZone

    if userMoved, !isAtBottom {
      let visible = quoteViewport
      if let place = topReadingPlace(visibleTop: visible.minY, visibleBottom: visible.maxY, width: visible.width) {
        chatRows.setHistoryAnchor(place.messageId)
      }
    }

    // Check if we're approaching the top
    if feature_loadsMoreWhenApproachingTop, userMoved, currentScrollOffset < viewportSize.height {
      loadBatch(at: .older)
    }

    if feature_loadsMoreWhenApproachingBottom,
       userMoved,
       maxScrollableHeight - currentScrollOffset < viewportSize.height
    {
      loadBatch(at: .newer)
    }

    if prevAtBottom != isAtBottom {
      let shouldShow = !isAtBottom // && messages.count > 0
      setScrollToBottomButtonShown(shouldShow)
      if isAtBottom {
        updateUnreadIfNeeded()
      }
    }
  }

  /// Using CFAbsoluteTimeGetCurrent()
  private func measureTime(_ closure: () -> Void, name: String = "Function") {
    let start = CFAbsoluteTimeGetCurrent()
    closure()
    let end = CFAbsoluteTimeGetCurrent()
    let timeElapsed = (end - start) * 1_000 // Convert to milliseconds
    log.trace("\(name) took \(String(format: "%.2f", timeElapsed))ms")
  }

  @objc func scrollViewFrameChanged(notification: Notification) {
    updateMessageViewColors()
    scheduleAvatarOverlaySync()
    refreshMessageHoverAfterGeometryChange()
  }

  private var lastKnownWidth: CGFloat = 0
  private var needsInitialScroll = true
  private var didQueueInitialFinalize = false

  private func hideScrollbars() {
    // Keep native overlay scrollers available during initial scroll positioning.
  }

  private func enableScrollbars() {
    scrollView.hasVerticalScroller = true
    scrollView.verticalScroller?.isHidden = false
    scrollView.verticalScroller?.alphaValue = 1.0
  }

  override func viewDidLayout() {
    viewDidLayoutCount += 1
    let shouldSignpost = viewDidLayoutCount <= 40
    let signpostID = OSSignpostID(log: Self.signpostLog)
    if shouldSignpost {
      os_signpost(
        .begin,
        log: Self.signpostLog,
        name: "MessageListViewDidLayout",
        signpostID: signpostID,
        "%{public}s",
        "count=\(viewDidLayoutCount) width=\(tableWidth()) rows=\(tableView.numberOfRows) messages=\(messages.count) initial=\(needsInitialScroll)"
      )
    }
    defer {
      if shouldSignpost {
        os_signpost(.end, log: Self.signpostLog, name: "MessageListViewDidLayout", signpostID: signpostID)
      }
    }

    super.viewDidLayout()
    #if DEBUG
    log.trace("viewDidLayout() called, width=\(tableWidth())")
    #endif
    defer {
      scheduleAvatarOverlaySync()
      refreshMessageHoverAfterGeometryChange()
    }

    observeToolbarDisplayModeIfNeeded()

    updateToolbar()

    updateColumnWidthAndCommit()

    updateScrollViewInsets()

    // Initial scroll to bottom
    if needsInitialScroll {
      guard let width = measurementWidth() else {
        return
      }

      finalizeInitialMeasurementWidthIfNeeded(width: width)

      if feature_recalculatesHeightsWhileInitialScroll {
        // Note(@mo): I still don't know why this fixes it but as soon as I compare the widths for the change,
        // it no longer works. this needs to be called unconditionally.
        // this is needed to ensure the scroll is done after the initial layout and prevents cutting off last msg
        // EXPERIMENTAL: GETTING RID OF THIS FOR PERFORMANCE REASONS
        // let _ = recalculateHeightsOnWidthChange(maintainScroll: false)

        // fullWidthAsyncCalc(maintainScroll: true)
      }

      // A targeted open must never paint the live bottom first; that also
      // overrides any later scroll request queued before this first layout.
      if !centerInitialTargetIfNeeded(), !placeInitialReadingPlaceIfNeeded() {
        scrollToBottom(animated: false)
      }

      // Every pass until then re-places the list; the finalize work is queued once.
      if !didQueueInitialFinalize {
        didQueueInitialFinalize = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
          guard let self else { return }
          // Finalize heights one last time to ensure no broken heights on initial load
          needsInitialScroll = false
          scheduleAvatarOverlaySync()
          focusInitialTargetIfNeeded()
          finishInitialReadingPlacement()
          if revealsAfterInitialPlacement {
            revealsAfterInitialPlacement = false
            revealListAfterLayout()
          }
          updateUnreadIfNeeded()
        }
      }
    }

    checkWidthChangeForHeights()
    scheduleChatNavigationReadyAfterInitialLayout()

    maintainReplyThreadSourceAnchorIfNeeded()
    maintainReadingHoldIfNeeded()
  }

  // MARK: - Reading place placement

  /// The row the list holds in place: the unread line's, or a saved reading place's message.
  private enum ReadingHoldRow: Equatable {
    case unreadLine
    case message(stableId: Int64)
  }

  /// A row whose top the list keeps `offset` points below the visible top (the top inset), as
  /// Telegram holds an unread landing until the user scrolls. The unread line is held at 0.
  private struct ReadingHold: Equatable {
    let row: ReadingHoldRow
    let offset: CGFloat
  }

  /// Nil when nothing is held.
  private var readingHold: ReadingHold?

  private func rowIndex(for row: ReadingHoldRow) -> Int? {
    switch row {
      case .unreadLine:
        chatRows.rows.firstIndex(of: .unreadSeparator)
      case let .message(stableId):
        chatRows.rowIndex(forMessageStableId: stableId)
    }
  }

  private func readingGeometry(row: Int) -> UnreadLineGeometry {
    let insets = scrollView.contentInsets
    return UnreadLineGeometry(
      lineTop: tableView.rect(ofRow: row).minY,
      documentHeight: scrollView.documentView?.frame.height ?? 0,
      viewportHeight: scrollView.contentView.bounds.height,
      topInset: insets.top,
      bottomInset: insets.bottom
    )
  }

  /// Opens at the saved reading place, else with the unread line at the top, in the initial
  /// layout passes, without animation. When the rows from there down fit on screen, the chat
  /// opens at the bottom as usual. The unread line is still drawn under a saved place.
  private func placeInitialReadingPlaceIfNeeded() -> Bool {
    guard initialTargetMessageId == nil else { return false }
    if let place = initialReadingPlace,
       let stableId = messages.first(where: { $0.message.messageId == place.messageId })?.id
    {
      // A saved place whose rows now fit on screen opens at the bottom. It is not handed to
      // the unread line, which can sit far above it.
      return placeInitialReadingHold(
        ReadingHold(row: .message(stableId: stableId), offset: place.offset),
        historyAnchor: place.messageId
      )
    }
    return placeInitialReadingHold(
      ReadingHold(row: .unreadLine, offset: 0),
      historyAnchor: chatRows.unreadLineMessageId
    )
  }

  private func placeInitialReadingHold(_ hold: ReadingHold, historyAnchor: Int64?) -> Bool {
    guard let row = rowIndex(for: hold.row) else { return false }
    // Landing puts the row's top at the visible top; an offset lowers that line by as much.
    var landing = readingGeometry(row: row)
    landing.lineTop -= hold.offset
    guard let origin = landing.landingOrigin else { return false }

    readingHold = hold
    isAtBottom = false
    // A window opened inside history leaves new messages to paging, as after a jump.
    if !chatRows.historyCoverage.isAtCertifiedLiveEnd, let historyAnchor {
      chatRows.setHistoryAnchor(historyAnchor)
    }
    beginProgrammaticScroll()
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: origin))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    endProgrammaticScroll()
    return true
  }

  /// Runs once initial measurement settles: pins the held row on final heights and insets, and
  /// refreshes the bottom state the initial pass skipped.
  private func finishInitialReadingPlacement() {
    initialReadingPlace = nil
    guard let hold = readingHold else { return }
    maintainReadingHoldIfNeeded()
    handleBoundsChange()
    #if DEBUG
    let bounds = scrollView.contentView.bounds
    let insets = scrollView.contentInsets
    let top = topReadingPlace(
      visibleTop: bounds.minY + insets.top, visibleBottom: bounds.maxY - insets.bottom, width: bounds.width
    )
    log.debug(
      "reading hold landed row=\(hold.row) offset=\(hold.offset) topMessage=\(top?.messageId ?? 0) topOffset=\(top?.offset ?? 0) atBottom=\(isAtBottom)"
    )
    #endif
    // Placement cleared the bottom state before the first bounds pass, so that pass saw no
    // transition to show the button for.
    setScrollToBottomButtonShown(!isAtBottom)
  }

  /// Keeps a held row where it landed through inset, width, height and window changes,
  /// clamped to the scroll range. Only the user or an explicit scroll releases it.
  private func maintainReadingHoldIfNeeded() {
    guard let hold = readingHold, !isUserScrolling, !isPerformingUpdate, !isDisposed else { return }
    guard let row = rowIndex(for: hold.row) else {
      readingHold = nil
      return
    }

    // Compare with where AppKit will actually go, so a hold clamped at a pixel-snapped limit
    // does not re-scroll on every layout pass.
    let target = clampScrollOffset(readingGeometry(row: row).heldOrigin(hold: hold.offset))
    guard abs(target - scrollView.contentView.bounds.minY) >= UnreadLineGeometry.tolerance else { return }
    beginProgrammaticScroll()
    scrollView.contentView.updateBounds(NSPoint(x: 0, y: target), cancel: true)
    endProgrammaticScroll()
  }

  private func releaseReadingHold() {
    readingHold = nil
  }

  // MARK: - Saving the reading place

  /// Set by a return to latest until the list lands at the bottom, the user scrolls or jumps,
  /// so the place it is leaving is not saved again while the latest messages load.
  private var readingPlaceCaptureBlocked = false

  /// Saves where the user is reading when the newest message is off screen, and clears the
  /// saved place when it is on screen. Skipped while the list is unplaced, hidden for the
  /// unread fetch, or moving through an animated jump, where its geometry is not the user's.
  private func captureReadingPlace() {
    guard isViewLoaded, !isDisposed, !needsInitialScroll, unreadFetchBoundary == nil, !isProgrammaticScroll,
          !isPerformingUpdate, tableView.numberOfRows == chatRows.rowCount, tableView.numberOfRows > 0
    else { return }

    let bounds = scrollView.contentView.bounds
    let insets = scrollView.contentInsets
    let visibleTop = bounds.minY + insets.top
    let visibleBottom = bounds.maxY - insets.bottom
    guard visibleBottom > visibleTop else { return }

    let store = ChatReadingPlaceStore.shared
    if isNewestMessageOnScreen(visibleBottom: visibleBottom) {
      readingPlaceCaptureBlocked = false
      store.clear(for: peerId)
      log.debug("reading place cleared: newest message on screen")
      return
    }
    guard !readingPlaceCaptureBlocked,
          let place = topReadingPlace(visibleTop: visibleTop, visibleBottom: visibleBottom, width: bounds.width)
    else { return }
    store.save(place, for: peerId)
    log.debug("reading place saved message=\(place.messageId) offset=\(place.offset)")
  }

  /// No newer message is cached past the window, and the last message row starts above the
  /// composer. A chat left a few lines up still opens at the bottom.
  private func isNewestMessageOnScreen(visibleBottom: CGFloat) -> Bool {
    guard !chatRows.canLoadNewerFromLocal else { return false }
    guard let lastMessageRow = chatRows.rows.lastIndex(where: {
      if case .message = $0 { return true }
      return false
    }) else { return true }
    return tableView.rect(ofRow: lastMessageRow).minY < visibleBottom
  }

  /// The first message row reaching below the top inset that has a server id, with its top's
  /// distance below that inset (negative when it starts under the toolbar).
  private func topReadingPlace(visibleTop: CGFloat, visibleBottom: CGFloat, width: CGFloat) -> ChatReadingPlace? {
    let range = tableView.rows(in: NSRect(x: 0, y: visibleTop, width: max(1, width), height: visibleBottom - visibleTop))
    guard range.location != NSNotFound, range.length > 0 else { return nil }

    for row in range.location ..< min(NSMaxRange(range), tableView.numberOfRows) {
      guard case .message? = rowItem(at: row),
            let message = message(forRow: row),
            message.message.messageId > 0
      else { continue }
      let rect = tableView.rect(ofRow: row)
      guard rect.maxY > visibleTop else { continue }
      return ChatReadingPlace(messageId: message.message.messageId, offset: rect.minY - visibleTop)
    }
    return nil
  }

  // MARK: - Uncached unread line

  private var unreadFetchTask: Task<Void, Never>?
  private var unreadFetchConnection: AnyCancellable?
  private var unreadFetchSpinner: NSProgressIndicator?
  /// The fetch ended inside the initial placement window; that pass reveals the list.
  private var revealsAfterInitialPlacement = false

  /// Opens a chat whose unread history isn't cached as Telegram does: the list stays hidden over
  /// its latest messages while history around the line is fetched, with no deadline, then appears
  /// at the line. Losing the connection, a failed fetch, or the user sending or jumping shows the
  /// latest messages instead. Either way the list lands once and never re-anchors later.
  private func beginUnreadFetchIfNeeded() {
    guard let boundary = unreadFetchBoundary else { return }
    scrollView.alphaValue = 0

    let peer = peerId
    unreadFetchTask = Task { @MainActor [weak self] in
      var placesLine = false
      var failure: Error?
      do {
        _ = try await MessageHistoryRepairCoordinator.shared.loadAround(
          peer: peer,
          anchorID: max(1, boundary),
          limit: ChatUnreadOpening.windowLimit
        )
        guard let self, unreadFetchBoundary == boundary, !Task.isCancelled else { return }
        placesLine = try await chatRows.loadUnreadOpeningWindow(boundary: boundary)
      } catch {
        failure = error
      }
      guard let self, unreadFetchBoundary == boundary, !Task.isCancelled else { return }
      if let failure {
        log.error("Unread history fetch failed; opening at the latest messages", error: failure)
      }
      endUnreadFetch(placesLine: placesLine)
    }

    // A send queued behind a lost connection would hold the list hidden until it returns.
    unreadFetchConnection = Api.realtime.stateObject.$connectionState
      .sink { [weak self] state in
        guard state == .connecting else { return }
        self?.endUnreadFetch(placesLine: false)
      }

    // A fast fetch reveals before any spinner shows.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self, unreadFetchBoundary == boundary, !isDisposed else { return }
      showUnreadFetchSpinner()
    }
  }

  private func endUnreadFetch(placesLine: Bool) {
    guard unreadFetchBoundary != nil, !isDisposed else { return }
    unreadFetchBoundary = nil
    // Cancelling also stops a window read in flight from replacing the rows shown below.
    unreadFetchTask?.cancel()
    unreadFetchTask = nil
    unreadFetchConnection = nil
    if let spinner = unreadFetchSpinner {
      unreadFetchSpinner = nil
      spinner.stopAnimation(nil)
      spinner.removeFromSuperview()
    }

    if placesLine {
      rebuildRowItems()
      clearHoveredMessage()
      tableView.reloadData()
      pruneMessageSelection()
      scheduleMessageHoverRefresh()
      if !placeInitialReadingPlaceIfNeeded() {
        scrollToBottom(animated: false)
      }
      finishInitialReadingPlacement()
    }

    if needsInitialScroll {
      revealsAfterInitialPlacement = true
    } else {
      revealListAfterLayout()
    }
    // Nothing was read or reported while the list was hidden.
    updateUnreadIfNeeded()
  }

  /// Fades the list in on the frame after placement, so the first frame shown is already settled.
  private func revealListAfterLayout() {
    DispatchQueue.main.async { [weak self] in
      guard let self, !isDisposed else { return }
      maintainReadingHoldIfNeeded()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        self.scrollView.animator().alphaValue = 1
      }
    }
  }

  private func showUnreadFetchSpinner() {
    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.isDisplayedWhenStopped = false
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.alphaValue = 0
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
    ])
    spinner.startAnimation(nil)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      spinner.animator().alphaValue = 1
    }
    unreadFetchSpinner = spinner
  }

  /// Positions the first viewport on the initial target without animation.
  private func centerInitialTargetIfNeeded() -> Bool {
    guard let targetId = initialTargetMessageId,
          let stableId = messages.first(where: { $0.message.messageId == targetId })?.id,
          let row = chatRows.rowIndex(forMessageStableId: stableId)
    else { return false }

    let viewportHeight = scrollView.contentView.bounds.height
    let documentHeight = scrollView.documentView?.frame.height ?? 0
    let maxY = max(0, documentHeight - viewportHeight)
    let targetY = min(maxY, max(0, tableView.rect(ofRow: row).midY - (viewportHeight / 2)))

    beginProgrammaticScroll()
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    endProgrammaticScroll()
    return true
  }

  /// Runs once initial measurement settles: re-centers on final heights,
  /// highlights the target, and refreshes bottom state skipped during setup.
  private func focusInitialTargetIfNeeded() {
    guard let targetId = initialTargetMessageId else { return }
    initialTargetMessageId = nil
    handleBoundsChange()
    scrollToMsgAndHighlight(ScrollToMessageRequest(messageId: targetId, reason: .link))
  }

  private func scheduleChatNavigationReadyAfterInitialLayout() {
    guard !didScheduleChatNavigationReady, !isDisposed else { return }
    didScheduleChatNavigationReady = true

    // Queue the end after the first message-list layout. This also captures synchronous main-thread
    // work that delays the callback, but it does not prove that Core Animation presented a frame.
    DispatchQueue.main.async { [weak self] in
      guard let self, !isDisposed else { return }
      dependencies.nav2?.endChatNavigationSignpost(peer: peerId, reason: "first_message_layout")
      dependencies.nav3?.endChatNavigationSignpost(peer: peerId, reason: "first_message_layout")
    }
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    log.trace("viewWillAppear() called")
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    log.trace("viewDidAppear() called")
    setupLiveResizeObserver()
    observeToolbarDisplayModeIfNeeded()
    updateScrollViewInsets()
    updateToolbar()
    scheduleAvatarOverlaySync()
    DispatchQueue.main.async { [weak self] in
      self?.lastVisibleReadCandidateID = nil
      self?.updateUnreadIfNeeded()
    }
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    log.trace("viewWillDisappear() called")
    // Leaving with the view still in its window, so its geometry is the one the user saw.
    captureReadingPlace()
  }

  override func viewDidDisappear() {
    super.viewDidDisappear()
    log.trace("viewDidDisappear() called")
    removeLiveResizeObserver()
    clearHoveredMessage()
    activityNavigator?.clearVisible()
  }

  override func viewWillLayout() {
    super.viewWillLayout()
    log.trace("viewWillLayout() called")
  }

  private func finalizeInitialMeasurementWidthIfNeeded(width: CGFloat) {
    guard !didFinalizeInitialMeasurementWidth else { return }
    guard tableView.numberOfRows > 0 else { return }

    // Initial sizing experiment:
    // The old path below tried broad recalculation during initial scroll. This pass is narrower in behavior:
    // once the real measurement width is available, synchronously re-note all row heights with animations disabled,
    // then scroll. If this regresses initial load, revert this helper and restore the commented
    // `recalculateHeightsOnWidthChange(maintainScroll: false)` / `fullWidthAsyncCalc` experiment in `viewDidLayout`.
    didFinalizeInitialMeasurementWidth = true
    lastKnownWidth = width

    let rows = IndexSet(integersIn: 0 ..< tableView.numberOfRows)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = 0

    tableView.beginUpdates()
    updateHeightsForRows(at: rows, width: width)
    tableView.noteHeightOfRows(withIndexesChanged: rows)
    tableView.endUpdates()

    NSAnimationContext.endGrouping()
    CATransaction.commit()
    syncAvatarOverlayAfterTableLayout()
    refreshMessageHoverAfterGeometryChange()
  }

  private var deferredWidthBuffer: Int?

  /// Called on did layout
  func checkWidthChangeForHeights() {
    guard feature_updatesHeightsOnWidthChange else { return }
    guard !needsInitialScroll else { return }

    #if DEBUG
    log.trace("Checking width change, diff = \(abs((measurementWidth() ?? 0) - lastKnownWidth))")
    #endif
    guard let newWidth = measurementWidth() else { return }

    if abs(newWidth - lastKnownWidth) > 0.5 {
      lastKnownWidth = newWidth
      recalculateHeightsOnWidthChange(buffer: 3, duringLiveResize: true)
    }
  }

  private var loadingBatch = false
  private var loadingRemoteOlderBatch = false
  private var noRemoteOlderBeforeMessageId: Int64?
  private var lastRemoteOlderCursor: Int64?

  private func shouldRequestRemoteOlder(beforeMessageId: Int64) -> Bool {
    guard beforeMessageId > 0 else { return false }

    if let noRemoteOlderBeforeMessageId, beforeMessageId <= noRemoteOlderBeforeMessageId {
      return false
    }

    if loadingRemoteOlderBatch, lastRemoteOlderCursor == beforeMessageId {
      return false
    }

    return true
  }

  private func loadDirectionLabel(_ direction: MessagesProgressiveViewModel.MessagesLoadDirection) -> String {
    switch direction {
      case .older:
        "older"
      case .newer:
        "newer"
    }
  }

  private func requestRemoteOlderBatch(beforeMessageId: Int64) {
    guard shouldRequestRemoteOlder(beforeMessageId: beforeMessageId) else { return }

    loadingRemoteOlderBatch = true
    lastRemoteOlderCursor = beforeMessageId

    remoteOlderTask?.cancel()
    remoteOlderTask = Task { [weak self] in
      guard let self else { return }
      defer { loadingRemoteOlderBatch = false }

      do {
        guard !Task.isCancelled else { return }
        let outcome = try await MessageHistoryRepairCoordinator.shared.loadOlder(
          peer: peerId,
          beforeID: beforeMessageId
        )
        guard !Task.isCancelled else { return }

        if outcome == .empty || outcome == .notNeeded {
          if let boundary = noRemoteOlderBeforeMessageId {
            noRemoteOlderBeforeMessageId = max(boundary, beforeMessageId)
          } else {
            noRemoteOlderBeforeMessageId = beforeMessageId
          }
          return
        }

        await MainActor.run { [weak self] in
          guard Task.isCancelled == false else { return }
          self?.loadBatch(at: .older, allowUnavailableLocal: true)
        }
      } catch is CancellationError {
        return
      } catch {
        log.error("Failed to load older messages from remote", error: error)
      }
    }
  }

  private func requestRemoteNewerBatch(afterMessageId: Int64) {
    guard remoteNewerTask == nil else { return }
    if let attempt = lastRemoteNewerAttempt, attempt.messageID == afterMessageId,
       Date().timeIntervalSince(attempt.date) < 2
    {
      return
    }
    lastRemoteNewerAttempt = (afterMessageId, Date())
    let peer = peerId
    remoteNewerTask = Task { @MainActor [weak self] in
      defer { self?.remoteNewerTask = nil }
      do {
        let outcome = try await MessageHistoryRepairCoordinator.shared.loadNewer(peer: peer, afterID: afterMessageId)
        guard let self, !Task.isCancelled, !isDisposed, outcome == .loaded else { return }
        loadBatch(at: .newer, allowUnavailableLocal: true)
      } catch is CancellationError {
        return
      } catch {
        self?.log.error("Failed to load newer history", error: error)
      }
    }
  }

  func loadBatch(
    at direction: MessagesProgressiveViewModel.MessagesLoadDirection,
    allowUnavailableLocal: Bool = false
  ) {
    if loadingBatch {
      return
    }
    loadingBatch = true

    loadBatchTask?.cancel()
    loadBatchTask = Task { [weak self] in
      guard let self else { return }
      defer {
        loadBatchTask = nil
        loadingBatch = false
      }
      guard !Task.isCancelled else {
        return
      }

      let boundaryMessageIdBeforeLoad = switch direction {
        case .older:
          messages.first?.message.messageId
        case .newer:
          messages.last?.message.messageId
      }

      log.trace("Loading \(loadDirectionLabel(direction)) batch")
      let didLoadLocalBatch = await chatRows.loadBatchAsync(
        at: direction, publish: false, allowUnavailableLocal: allowUnavailableLocal
      )
      guard !Task.isCancelled else { return }

      let didInsertRows = didLoadLocalBatch && applyLoadedBatch()

      guard !Task.isCancelled else { return }
      guard !didInsertRows else { return }

      switch direction {
        case .older:
          guard let boundaryMessageIdBeforeLoad else { return }
          guard !chatRows.canLoadOlderFromLocal else { return }
          requestRemoteOlderBatch(beforeMessageId: boundaryMessageIdBeforeLoad)

        case .newer:
          guard let boundaryMessageIdBeforeLoad, chatRows.needsNewerHistoryRepair else { return }
          requestRemoteNewerBatch(afterMessageId: boundaryMessageIdBeforeLoad)
      }
    }
  }

  /// Capture after the page read. Either edge can yield a replacement window when
  /// a publication or a coverage change is reconciled with the page.
  private func applyLoadedBatch() -> Bool {
    let anchors = viewport.anchors()
    let rowUpdate = chatRows.syncFromViewModelAfterManualMutation()
    guard rowUpdate != .none else { return false }

    clearHoveredMessage()
    if case let .insert(inserted) = rowUpdate {
      tableView.beginUpdates()
      tableView.insertRows(at: inserted, withAnimation: .none)
      tableView.endUpdates()
      reloadGroupBoundaryRows(groupBoundaryRefreshRows(aroundInsertedRows: inserted))
    } else {
      tableView.reloadData()
    }
    tableView.layoutSubtreeIfNeeded()
    if let anchor = anchors.first(where: { viewport.index(of: $0) != nil }) {
      viewport.restore(anchor)
    }
    maintainReadingHoldIfNeeded()
    syncAvatarOverlayAfterTableLayout()
    scheduleMediaWarmupForVisibleAndNearby(reason: "local_batch")
    scheduleMessageHoverRefresh()
    pruneMessageSelection()
    return true
  }

  func applyInitialData() {
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "MacMessagesInitialReload",
      category: .messages,
      "messages=\(messages.count)"
    )
    defer {
      span.end(
        "messages=\(messages.count) rows=\(tableView.numberOfRows) duration_ms=\(PerformanceTrace.elapsedMilliseconds(since: startedAt))"
      )
    }
    rebuildRowItems()
    clearHoveredMessage()
    tableView.reloadData()
    pruneMessageSelection()
    syncAvatarOverlayAfterTableLayout()
    scheduleMediaWarmupForVisibleAndNearby(reason: "initial")
    scheduleMessageHoverRefresh()
  }

  func applyUpdate(_ update: MessagesProgressiveViewModel.MessagesChangeSet) {
    let updateLabel = update.traceLabel
    let beforeRows = tableView.numberOfRows
    let beforeMessages = messages.count
    let startedAt = Date()
    let span = PerformanceTrace.begin(
      "MacMessagesApplyUpdate",
      category: .messages,
      "type=\(updateLabel) rows=\(beforeRows) messages=\(beforeMessages)"
    )
    var didSyncAvatarOverlayForUpdate = false
    defer {
      if !didSyncAvatarOverlayForUpdate {
        scheduleAvatarOverlaySync()
      }
      scheduleMediaWarmupForVisibleAndNearby(reason: "update_\(updateLabel)")
      scheduleMessageHoverRefresh()
      let durationMs = PerformanceTrace.elapsedMilliseconds(since: startedAt)
      span.end(
        "type=\(updateLabel) rows_before=\(beforeRows) rows_after=\(tableView.numberOfRows) messages_before=\(beforeMessages) messages_after=\(messages.count) duration_ms=\(durationMs)"
      )
      PerformanceTrace.slowBreadcrumb(
        "slow mac messages apply update",
        category: "messages.mac",
        durationMs: durationMs,
        thresholdMs: 120,
        data: [
          "type": updateLabel,
          "rows_before": beforeRows,
          "rows_after": tableView.numberOfRows,
          "messages_before": beforeMessages,
          "messages_after": messages.count,
        ]
      )
    }

    tableUpdateCount += 1

    // Only new arrivals use the wider follow zone. Other mutations preserve the reading row.
    let animationDuration = debug_slowAnimation ? 1.5 : 0.15
    let shouldScroll: Bool
    switch update {
      case .added: shouldScroll = feature_scrollsToBottomOnNewMessage && canFollowBottom && isWithinFollowZone
      default: shouldScroll = shouldKeepBottomPinned
    }
    let anchors = shouldScroll ? [] : viewport.anchors()
    let rowUpdate = chatRows.apply(update)
    let updateAnchor = anchors.first { viewport.index(of: $0) != nil }
    defer { pruneMessageSelection() }
    if rowUpdate != .none {
      clearHoveredMessage()
    }

    func syncUpdateAvatarOverlayAfterTableLayout(on controller: MessageListAppKit, animate: Bool = false) {
      didSyncAvatarOverlayForUpdate = true
      controller.syncAvatarOverlayAfterTableLayout(animate: animate)
    }

    func reloadAll(animated: Bool, preserving anchor: VisibleMessageAnchor? = nil) {
      if animated, anchor == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        NSAnimationContext.runAnimationGroup { [weak self] context in
          guard let self else { return }
          context.duration = animationDuration
          tableView.reloadData()
          tableView.layoutSubtreeIfNeeded()
          syncUpdateAvatarOverlayAfterTableLayout(on: self, animate: true)
          if shouldScroll {
            scrollToBottom(animated: true)
          }
        } completionHandler: { [weak self] in
          self?.endTableUpdate()
        }
      } else {
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        if let anchor {
          viewport.restore(anchor)
        }
        syncUpdateAvatarOverlayAfterTableLayout(on: self)
        if shouldScroll {
          scrollToBottom(animated: false)
        }
        endTableUpdate()
      }
    }

    func applyStructuralInsert(animated: Bool, inserted: IndexSet) {
      let boundaryRows = groupBoundaryRefreshRows(aroundInsertedRows: inserted)
      // NSTableView keeps the clip origin, so rows inserted above the visible ones would push
      // them down. Those go in without animation and the visible rows are put back.
      var keptAnchor: VisibleMessageAnchor?
      if let updateAnchor,
         let anchorRow = viewport.index(of: updateAnchor),
         let firstInserted = inserted.first, firstInserted < anchorRow
      {
        keptAnchor = updateAnchor
      }

      if animated, keptAnchor == nil {
        NSAnimationContext.runAnimationGroup { [weak self] context in
          guard let self else { return }
          context.duration = animationDuration
          tableView.insertRows(at: inserted, withAnimation: .effectFade)
          reloadGroupBoundaryRows(boundaryRows)
          syncUpdateAvatarOverlayAfterTableLayout(on: self, animate: true)
          if shouldScroll {
            scrollToBottom(animated: true)
          }
        } completionHandler: { [weak self] in
          self?.endTableUpdate()
        }
      } else {
        tableView.beginUpdates()
        tableView.insertRows(at: inserted, withAnimation: .none)
        tableView.endUpdates()
        reloadGroupBoundaryRows(boundaryRows)
        if let keptAnchor {
          tableView.layoutSubtreeIfNeeded()
          viewport.restore(keptAnchor)
        }
        syncUpdateAvatarOverlayAfterTableLayout(on: self)
        if shouldScroll {
          scrollToBottom(animated: false)
        }
        endTableUpdate()
      }
    }

    func applyStructuralRemove(animated: Bool, removed: IndexSet) {
      // NSTableView keeps the clip origin, so rows removed above the visible ones would pull
      // them up. Those go without animation and the visible rows are put back.
      var keptAnchor: VisibleMessageAnchor?
      if let updateAnchor, let firstRemoved = removed.first, firstRemoved < updateAnchor.oldIndex {
        keptAnchor = updateAnchor
      }

      if animated, keptAnchor == nil {
        NSAnimationContext.runAnimationGroup { [weak self] context in
          guard let self else { return }
          context.duration = animationDuration
          tableView.removeRows(at: removed, withAnimation: .effectFade)
          syncUpdateAvatarOverlayAfterTableLayout(on: self, animate: true)
          if shouldScroll {
            scrollToBottom(animated: true)
          }
        } completionHandler: { [weak self] in
          self?.endTableUpdate()
        }
      } else {
        tableView.beginUpdates()
        tableView.removeRows(at: removed, withAnimation: .none)
        tableView.endUpdates()
        if let keptAnchor {
          tableView.layoutSubtreeIfNeeded()
          viewport.restore(keptAnchor)
        }
        syncUpdateAvatarOverlayAfterTableLayout(on: self)
        if shouldScroll {
          scrollToBottom(animated: false)
        }
        endTableUpdate()
      }
    }

    switch update {
      case let .added(newMessages, _):
        log.trace("applying add changes")

        switch rowUpdate {
          case let .insert(inserted):
            applyStructuralInsert(animated: true, inserted: inserted)
          case .none:
            if shouldScroll {
              scrollToBottom(animated: true)
            }
            endTableUpdate()
          case .reloadAll, .remove(_), .reloadRows:
            reloadAll(animated: true, preserving: updateAnchor)
        }
        updateScrollToBottomCount()
        if let pendingID = pendingArrivalMessageID,
           newMessages.contains(where: { $0.message.messageId == pendingID })
        {
          pendingArrivalMessageID = nil
          let revision = targetScrollRevision
          DispatchQueue.main.async { [weak self] in
            guard let self, !isDisposed, targetScrollRevision == revision else { return }
            scrollToMessage(pendingID, shouldHighlight: true)
          }
        }

      case .deleted:
        switch rowUpdate {
          case let .remove(removed):
            applyStructuralRemove(animated: true, removed: removed)
          case .none:
            if shouldScroll {
              scrollToBottom(animated: true)
            }
            endTableUpdate()
          case .reloadAll, .insert(_), .reloadRows:
            reloadAll(animated: true, preserving: updateAnchor)
        }

      case let .updated(updatedMessages, indexSet, animated):
        _ = updatedMessages // silence unused warning
        _ = indexSet // row updates are resolved by chatRows

        switch rowUpdate {
          case let .reloadRows(rowsToReload):
            if rowsToReload.isEmpty {
              endTableUpdate()
              break
            }

            let movesAnchor = updateAnchor?.hasChangesAbove(rowsToReload) == true
            if animated == true, !movesAnchor, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
              NSAnimationContext.runAnimationGroup { [weak self] context in
                guard let self else { return }
                context.duration = animationDuration
                tableView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet([0]))
                tableView.noteHeightOfRows(withIndexesChanged: rowsToReload)
                updateHeightsForRows(at: rowsToReload)
                tableView.layoutSubtreeIfNeeded()
                if let updateAnchor {
                  viewport.restore(updateAnchor)
                }
                syncUpdateAvatarOverlayAfterTableLayout(on: self, animate: true)
                if shouldScroll {
                  scrollToBottom(animated: true)
                }
              } completionHandler: { [weak self] in
                self?.endTableUpdate()
              }
            } else {
              tableView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet([0]))
              tableView.noteHeightOfRows(withIndexesChanged: rowsToReload)
              updateHeightsForRows(at: rowsToReload)
              tableView.layoutSubtreeIfNeeded()
              if let updateAnchor {
                viewport.restore(updateAnchor)
              }
              syncUpdateAvatarOverlayAfterTableLayout(on: self)
              if shouldScroll {
                scrollToBottom(animated: false)
              }
              endTableUpdate()
            }

          case .none:
            endTableUpdate()

          case .reloadAll, .insert(_), .remove:
            reloadAll(animated: animated == true, preserving: updateAnchor)
        }

      case .reload:
        log.trace("reloading data")
        reloadAll(animated: false, preserving: updateAnchor)
    }
  }

  private func recalculateHeightsOnWidthChange(
    buffer: Int = 0,
    duringLiveResize: Bool = false
  ) {
    heightRecalcCount += 1

    #if DEBUG
    log.trace("Recalculating heights on width change")
    #endif

    if isPerformingUpdate {
      deferredWidthBuffer = max(buffer, deferredWidthBuffer ?? 0)
      return
    }

    let visibleRect = tableView.visibleRect
    let visibleRange = tableView.rows(in: visibleRect)

    guard visibleRange.location != NSNotFound else { return }

    // Calculate ranges
    let visibleStartIndex = max(0, visibleRange.location - buffer)
    let visibleEndIndex = min(
      tableView.numberOfRows,
      visibleRange.location + visibleRange.length + buffer
    )

    if visibleStartIndex >= visibleEndIndex {
      return
    }

    // First, immediately update visible rows
    let rowsToUpdate = IndexSet(integersIn: visibleStartIndex ..< visibleEndIndex)
    let shouldSignpost = heightRecalcCount <= 80
    let signpostID = OSSignpostID(log: Self.signpostLog)
    if shouldSignpost {
      os_signpost(
        .begin,
        log: Self.signpostLog,
        name: "MessageListHeightRecalc",
        signpostID: signpostID,
        "%{public}s",
        "count=\(heightRecalcCount) rows=\(rowsToUpdate.count) width=\(tableWidth()) initial=\(needsInitialScroll) live=\(duringLiveResize)"
      )
    }
    defer {
      if shouldSignpost {
        os_signpost(.end, log: Self.signpostLog, name: "MessageListHeightRecalc", signpostID: signpostID)
      }
    }

    #if DEBUG
    log.trace("Rows to update: \(rowsToUpdate)")
    #endif
    let pinned = shouldKeepBottomPinned
    let anchor = pinned ? nil : viewport.anchors().first
    CATransaction.begin()
    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = 0

    tableView.beginUpdates()
    // Update heights in cells and setNeedsDisplay
    updateHeightsForRows(at: rowsToUpdate)

    // Experimental: noteheight of rows was below reload data initially
    tableView.noteHeightOfRows(withIndexesChanged: rowsToUpdate)
    tableView.endUpdates()

    restoreAfterRemeasure(pinned: pinned, anchor: anchor)
    maintainReadingHoldIfNeeded()
    NSAnimationContext.endGrouping()
    CATransaction.commit()
    syncAvatarOverlayAfterTableLayout()
    refreshMessageHoverAfterGeometryChange()
  }

  private func restoreAfterRemeasure(pinned: Bool, anchor: VisibleMessageAnchor?) {
    tableView.layoutSubtreeIfNeeded()
    if pinned {
      tableView.scrollToBottomWithInset(cancel: true)
    } else if let anchor {
      viewport.restore(anchor)
    }
  }

  private func updateHeightsForRows(at indexSet: IndexSet, width: CGFloat? = nil) {
    guard let width = width ?? measurementWidth() else { return }

    for row in indexSet {
      if let rowView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCell {
        let inputProps = messageProps(for: row)
        if let message = message(forRow: row) {
          let (_, _, _, plan) = calculateSize(
            for: message,
            with: inputProps,
            tableWidth: width
          )

          let props = MessageViewProps(
            firstInGroup: inputProps.firstInGroup,
            lastInGroup: inputProps.lastInGroup,
            startsAfterDaySeparator: inputProps.startsAfterDaySeparator,
            isLastMessage: inputProps.isLastMessage,
            isFirstMessage: inputProps.isFirstMessage,
            isRtl: inputProps.isRtl,
            isDM: inputProps.isDM,
            renderStyle: inputProps.renderStyle,
            index: chatRows.messageIndex(forStableMessageId: message.id),
            translated: inputProps.translated,
            interactionMode: interactionMode(for: row),
            replyThreadTitle: inputProps.replyThreadTitle,
            usesAvatarOverlay: usesAvatarOverlay(forRow: row),
            layout: plan
          )

          rowView.updateSizeWithProps(props: props)
        }
      }
    }
  }

  private func groupBoundaryRefreshRows(aroundInsertedRows inserted: IndexSet) -> IndexSet {
    var rows = IndexSet()

    for range in inserted.rangeView {
      guard let firstInsertedRow = firstMessageRow(in: range),
            let lastInsertedRow = lastMessageRow(in: range)
      else {
        continue
      }

      let previousRow = firstInsertedRow - 1
      if previousRow >= 0, canGroupRows(previousRow, firstInsertedRow) {
        rows.insert(previousRow)
      }

      let nextRow = range.upperBound
      if nextRow < tableView.numberOfRows, canGroupRows(lastInsertedRow, nextRow) {
        rows.insert(nextRow)
      }
    }

    rows.subtract(inserted)
    return rows
  }

  private func firstMessageRow(in range: Range<Int>) -> Int? {
    range.first { messageStableId(forRow: $0) != nil }
  }

  private func lastMessageRow(in range: Range<Int>) -> Int? {
    range.reversed().first { messageStableId(forRow: $0) != nil }
  }

  private func reloadGroupBoundaryRows(_ rows: IndexSet) {
    guard !rows.isEmpty else { return }

    #if DEBUG
    PerformanceTrace.event(
      "MacMessagesGroupBoundaryRefresh",
      category: .messages,
      "rows=\(Array(rows))"
    )
    #endif

    tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    tableView.noteHeightOfRows(withIndexesChanged: rows)
    refreshMessageHoverAfterGeometryChange()
  }

  private func canGroupRows(_ earlierRow: Int, _ laterRow: Int) -> Bool {
    guard let earlier = message(forRow: earlierRow), let later = message(forRow: laterRow) else {
      return false
    }
    return canGroup(earlier, later)
  }

  enum RowGroup {
    case all
    case visible
  }

  /// precalculate heights for a width
  private func precalculateHeightsInBackground(rowGroup: RowGroup = .all, width: CGFloat? = nil) {
    log.trace("precalculateHeightsInBackground")
    guard let width_ = width ?? measurementWidth() else { return }
    // for now
    let rowsToUpdate: IndexSet
    switch rowGroup {
      case .all:
        rowsToUpdate = IndexSet(integersIn: 0 ..< tableView.numberOfRows)
      case .visible:
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        rowsToUpdate = IndexSet(integersIn: visibleRange.location ..< visibleRange.location + visibleRange.length)
    }

    heightPrecalcTask?.cancel()
    heightPrecalcTask = Task(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      for row in rowsToUpdate {
        guard !Task.isCancelled else { return }
        guard let message = message(forRow: row) else { continue }
        let props = messageProps(for: row)
        let _ = calculateSize(for: message, with: props, tableWidth: width_)
      }
    }
  }

  private func scheduleMediaWarmupForVisibleAndNearby(reason: String) {
    guard isViewLoaded, !isDisposed else { return }

    mediaWarmupTask?.cancel()
    mediaWarmupTask = Task { @MainActor [weak self] in
      guard let self, !self.isDisposed else { return }
      let previousWarmups = mediaWarmups
      mediaWarmups.removeAll()
      for warmup in previousWarmups {
        await InlineTinyThumbnailPrewarmer.cancel(warmup)
      }

      await Task.yield()
      guard !Task.isCancelled, !isDisposed else { return }

      let groups = mediaWarmupRowsAroundVisible()
      let visibleMessages = groups.visible.compactMap { self.message(forRow: $0) }
      let nearbyMessages = groups.nearby.compactMap { self.message(forRow: $0) }
      var newWarmups: [InlineTinyThumbnailWarmup] = []

      if !visibleMessages.isEmpty {
        let visibleWarmup = await InlineTinyThumbnailPrewarmer.beginWarmup(
          for: visibleMessages,
          includeSupportingMedia: true,
          priority: .visible
        )
        newWarmups.append(visibleWarmup)
      }

      if !nearbyMessages.isEmpty, !Task.isCancelled {
        let nearbyWarmup = await InlineTinyThumbnailPrewarmer.beginWarmup(
          for: nearbyMessages,
          includeSupportingMedia: true,
          priority: .nearby
        )
        newWarmups.append(nearbyWarmup)
      }

      guard !Task.isCancelled, !isDisposed else {
        for warmup in newWarmups {
          await InlineTinyThumbnailPrewarmer.cancel(warmup)
        }
        return
      }

      mediaWarmups = newWarmups
      prewarmMediaForRows(groups.visible.union(groups.nearby), reason: reason)
    }
  }

  private func mediaWarmupRowsAroundVisible() -> (visible: IndexSet, nearby: IndexSet) {
    let rowCount = tableView.numberOfRows
    guard rowCount > 0 else { return ([], []) }

    let visibleRange = tableView.rows(in: tableView.visibleRect)
    guard visibleRange.location != NSNotFound, visibleRange.length > 0 else {
      let start = max(0, rowCount - mediaWarmupLookaheadRows)
      return ([], IndexSet(integersIn: start ..< rowCount))
    }

    let visibleEnd = min(rowCount, visibleRange.location + visibleRange.length)
    let visible = IndexSet(integersIn: visibleRange.location ..< visibleEnd)
    let nearbyBuffer = min(2, mediaWarmupLookaheadRows)
    let start = max(0, visibleRange.location - nearbyBuffer)
    let end = min(rowCount, visibleRange.location + visibleRange.length + mediaWarmupLookaheadRows)
    guard start < end else { return (visible, []) }
    var nearby = IndexSet(integersIn: start ..< end)
    nearby.subtract(visible)
    return (visible, nearby)
  }

  private var mediaWarmupLookaheadRows: Int {
    InlineTinyThumbnailWarmupPolicy.adaptiveLookaheadRows()
  }

  private func prewarmMediaForRows(_ rows: IndexSet, reason _: String) {
    guard let width = measurementWidth() else { return }
    let scale = mediaWarmupScale

    for row in rows {
      guard !isDisposed else { return }
      guard let message = message(forRow: row) else { continue }

      let props = messageProps(for: row)
      let (_, _, _, layoutPlan) = calculateSize(
        for: message,
        with: props,
        tableWidth: width
      )

      prewarmMedia(in: message, layout: layoutPlan, scale: scale)
    }
  }

  private var mediaWarmupScale: CGFloat {
    scrollView.window?.backingScaleFactor
      ?? view.window?.backingScaleFactor
      ?? NSScreen.main?.backingScaleFactor
      ?? 2
  }

  private func prewarmMedia(
    in fullMessage: FullMessage,
    layout: MessageSizeCalculator.LayoutPlans,
    scale: CGFloat
  ) {
    let hasCaption = fullMessage.message.text?.isEmpty == false

    if let photoInfo = fullMessage.photoInfo {
      prewarmPhotoDisplay(
        photoInfo,
        cacheKey: nil,
        targetSize: layout.photo?.size,
        hasCaption: hasCaption,
        scale: scale
      )
    }

    if let videoInfo = fullMessage.videoInfo {
      if let thumbnail = videoInfo.thumbnail {
        let videoId = videoInfo.video.id ?? thumbnail.id
        prewarmPhotoDisplay(
          thumbnail,
          cacheKey: "video-thumb-\(videoId)",
          targetSize: layout.video?.size,
          hasCaption: hasCaption,
          scale: scale
        )
      }
    }
  }

  private func prewarmPhotoDisplay(
    _ photoInfo: PhotoInfo?,
    cacheKey: String?,
    targetSize: CGSize?,
    hasCaption: Bool,
    scale: CGFloat
  ) {
    guard let photoSize = photoInfo?.bestPhotoSize(),
          let localPath = photoSize.localPath,
          !localPath.isEmpty
    else {
      return
    }

    let url = FileCache.getUrl(for: .photos, localPath: localPath)
    let resolvedTargetSize = mediaTargetSize(
      preferred: targetSize,
      photoSize: photoSize,
      hasCaption: hasCaption
    )

    ImageCacheManager.shared.prewarm(
      for: url,
      cacheKey: cacheKey,
      targetSize: resolvedTargetSize,
      scale: scale
    )
  }

  private func mediaTargetSize(
    preferred: CGSize?,
    photoSize: PhotoSize,
    hasCaption: Bool
  ) -> CGSize {
    if let preferred,
       preferred.width > 0,
       preferred.height > 0
    {
      return preferred
    }

    guard let width = photoSize.width,
          let height = photoSize.height
    else {
      return CGSize(width: 320, height: 320)
    }

    return sizeCalculator.calculatePhotoSize(
      width: CGFloat(width),
      height: CGFloat(height),
      parentAvailableWidth: 320,
      hasCaption: hasCaption
    )
  }

  private func message(forRow row: Int) -> FullMessage? {
    guard let stableId = messageStableId(forRow: row) else { return nil }
    return messageAndIndex(forStableId: stableId)?.message
  }

  private func getCachedSize(forRow row: Int) -> CGSize? {
    guard let stableId = messageStableId(forRow: row) else { return nil }
    return sizeCalculator.cachedSize(messageStableId: stableId)
  }

  // TODO: cache it
  private func getIsChatTranslated() -> Bool {
    TranslationState.shared.isTranslationEnabled(for: peerId)
  }

  private func messageProps(for row: Int) -> MessageViewInputProps {
    if case .parentMessage? = rowItem(at: row) {
      let message = message(forRow: row)
      return MessageViewInputProps(
        firstInGroup: true,
        lastInGroup: true,
        startsAfterDaySeparator: false,
        isLastMessage: true,
        isFirstMessage: true,
        isDM: false,
        isRtl: isRTLMessage(message),
        translated: message?.isTranslated ?? false,
        renderStyle: messageRenderStyle,
        interactionMode: interactionMode(for: row),
        replyThreadTitle: replyThreadTitle(for: message)
      )
    }

    guard let message = message(forRow: row) else {
      return MessageViewInputProps(
        firstInGroup: true,
        lastInGroup: true,
        startsAfterDaySeparator: false,
        isLastMessage: true,
        isFirstMessage: true,
        isDM: chat?.type == .privateChat,
        isRtl: false,
        translated: false,
        renderStyle: messageRenderStyle,
        interactionMode: interactionMode(for: row),
        replyThreadTitle: nil
      )
    }

    return MessageViewInputProps(
      firstInGroup: isFirstInGroup(at: row),
      lastInGroup: isLastInGroup(at: row),
      startsAfterDaySeparator: startsAfterDaySeparator(row: row),
      isLastMessage: isLastMessage(at: row),
      isFirstMessage: isFirstMessage(at: row),
      isDM: chat?.type == .privateChat,
      isRtl: isRTLMessage(message),
      translated: message.isTranslated,
      renderStyle: messageRenderStyle,
      interactionMode: interactionMode(for: row),
      replyThreadTitle: replyThreadTitle(for: message)
    )
  }

  private func replyThreadTitle(for message: FullMessage?) -> String? {
    message?.threadCardTitle
  }

  private func calculateSize(
    for message: FullMessage,
    with props: MessageViewInputProps,
    tableWidth: CGFloat
  ) -> (NSSize, NSSize, NSSize?, MessageSizeCalculator.LayoutPlans) {
    if message.message.isServiceMessage {
      return sizeCalculator.calculateServiceSize(for: message, with: props, tableWidth: tableWidth)
    }

    switch props.renderStyle {
      case .bubble:
        return sizeCalculator.calculateBubbleSize(for: message, with: props, tableWidth: tableWidth)
      case .minimal:
        return sizeCalculator.calculateMinimalSize(for: message, with: props, tableWidth: tableWidth)
    }
  }

  private func calculateNewHeight(forRow row: Int) -> CGFloat {
    guard let message = message(forRow: row) else {
      return defaultRowHeight
    }

    let props = messageProps(for: row)
    guard let width = measurementWidth(using: tableView, renderStyle: props.renderStyle) else {
      return getCachedSize(forRow: row)?.height ?? defaultRowHeight
    }

    let (_, _, _, plan) = calculateSize(for: message, with: props, tableWidth: width)
    return plan.totalHeight
  }

  deinit {
    dispose()

    log.trace("Deinit: \(type(of: self)) - \(self)")
  }

  // MARK: - Translation

  private func handleTranslationForUpdate(_ update: MessagesProgressiveViewModel.MessagesChangeSet) {
    guard AppSettings.shared.translationUIEnabled else { return }
    switch update {
      case .reload:
        // Trigger translation on all current messages
        scheduleTranslationWork(messages: messages, analyzeForDetection: true)

      case let .added(addedMessages, _):
        // Trigger translation on added messages
        if !addedMessages.isEmpty {
          scheduleTranslationWork(messages: addedMessages, analyzeForDetection: true)
        }

      case let .updated(updatedMessages, _, _):
        // Handle updated messages
        if !updatedMessages.isEmpty {
          scheduleTranslationWork(messages: updatedMessages, analyzeForDetection: false)
        }

      case .deleted:
        // No action needed for deletes
        break
    }
  }

  private func scheduleTranslationWork(messages: [FullMessage], analyzeForDetection: Bool) {
    guard AppSettings.shared.translationUIEnabled else { return }
    let messages = messages.filter { !$0.message.isServiceMessage }
    guard !messages.isEmpty else { return }

    deferredTranslationTask?.cancel()
    deferredTranslationTask = Task(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      await performTranslationWork(messages: messages, analyzeForDetection: analyzeForDetection)
    }
  }

  private func performTranslationWork(messages: [FullMessage], analyzeForDetection: Bool) async {
    guard AppSettings.shared.translationUIEnabled else { return }
    // Avoid competing with initial layout/scroll. Translation work is safe to delay.
    if needsInitialScroll, !hasDeferredInitialTranslation {
      await MainActor.run {
        self.hasDeferredInitialTranslation = true
      }
      await delayForInitialScroll()
      if Task.isCancelled {
        return
      }
    }

    translationViewModel.messagesDisplayed(messages: messages)

    guard analyzeForDetection, !hasAnalyzedInitialMessages else { return }

    await TranslationDetector.shared.analyzeMessages(peer: peerId, messages: messages)
    await MainActor.run {
      self.hasAnalyzedInitialMessages = true
    }
  }

  private func delayForInitialScroll() async {
    try? await Task.sleep(nanoseconds: 250_000_000)
  }

  // MARK: - Unread

  func updateUnreadIfNeeded() {
    guard AppActivityMonitor.shared.isActive else { return }
    guard isViewLoaded,
          let window = view.window,
          window.isVisible,
          !view.isHiddenOrHasHiddenAncestor
    else { return }

    // Nothing is read before the list has landed: until then it sits at the bottom of the
    // latest page, hidden or unplaced, and would read past an unread line it is about to open at.
    guard !needsInitialScroll, unreadFetchBoundary == nil else { return }

    if isWithinFollowZone, chatRows.historyCoverage.isAtCertifiedLiveEnd {
      // The bottom of a partial history window is not the end of the chat.
      // Clear everything only after the loaded page reaches the certified live end.
      UnreadManager.shared.readAll(peerId, chatId: chatId)
    } else {
      // In history the read marker follows what was on screen. A read the coverage
      // cannot certify waits until that history has been loaded.
      readVisibleIncomingMessages()
    }
    reportVisibleActivity()
  }

  private func readVisibleIncomingMessages() {
    let coverage = chatRows.historyCoverage
    if coverage != lastVisibleReadCoverage {
      lastVisibleReadCoverage = coverage
      lastVisibleReadCandidateID = nil
    }
    guard let highestVisibleIncomingID = highestVisibleIncomingMessageID(),
          highestVisibleIncomingID > (lastVisibleReadCandidateID ?? 0)
    else { return }
    lastVisibleReadCandidateID = highestVisibleIncomingID
    UnreadManager.shared.readVisible(
      peerId: peerId,
      chatId: chatId,
      highestVisibleIncomingID: highestVisibleIncomingID
    )
    if highestVisibleIncomingID > unreadCountReadFrontier {
      unreadCountReadFrontier = highestVisibleIncomingID
      updateScrollToBottomCount()
    }
  }

  /// All on-screen messages: mentions arrive on others' messages, reactions on yours.
  private func visibleMessageIDs() -> [Int64] {
    let visibleRect = tableView.visibleRect
    let visibleRange = tableView.rows(in: visibleRect)
    guard visibleRange.location != NSNotFound, visibleRange.length > 0 else { return [] }

    let upperBound = min(NSMaxRange(visibleRange), tableView.numberOfRows)
    return (visibleRange.location ..< upperBound).compactMap { row -> Int64? in
      guard case .message? = rowItem(at: row),
            tableView.rect(ofRow: row).intersects(visibleRect),
            let message = message(forRow: row),
            message.message.messageId > 0
      else { return nil }
      return message.message.messageId
    }
  }

  private func highestVisibleIncomingMessageID() -> Int64? {
    let visibleRect = tableView.visibleRect
    let visibleRange = tableView.rows(in: visibleRect)
    guard visibleRange.location != NSNotFound, visibleRange.length > 0 else { return nil }

    let upperBound = min(NSMaxRange(visibleRange), tableView.numberOfRows)
    return (visibleRange.location ..< upperBound).compactMap { row -> Int64? in
      guard case .message? = rowItem(at: row),
            tableView.rect(ofRow: row).intersects(visibleRect),
            let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false),
            !cell.isHiddenOrHasHiddenAncestor,
            let message = message(forRow: row),
            !message.message.isServiceMessage,
            message.message.messageId > 0,
            message.message.out != true
      else { return nil }
      return message.message.messageId
    }.max()
  }

  /// Unread messages below the reader, falling as they scroll and kept across reopening.
  private func updateScrollToBottomCount() {
    let state = activityNavigator?.state ?? .empty
    scrollToBottomButton.setCount(ChatUnreadBadgeCount.resolve(
      unreadCount: state.unreadCount,
      readInboxMaxId: state.readInboxMaxId,
      readFrontier: unreadCountReadFrontier,
      coverage: chatRows.historyCoverage,
      loadedMessages: messages
    ))
  }
}

final class DateSeparatorTableCell: NSView {
  static let height: CGFloat = 34
  private static let labelYOffset: CGFloat = -4

  private let label = NSTextField(labelWithString: "")
  private var currentDayStart: Date?

  override init(frame: NSRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = .clear

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 12, weight: .regular)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail

    addSubview(label)

    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Self.labelYOffset),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
    ])
  }

  func configure(dayStart: Date) {
    guard currentDayStart != dayStart else { return }
    currentDayStart = dayStart
    label.stringValue = Self.displayString(for: dayStart)
  }

  private static func displayString(for dayStart: Date) -> String {
    let calendar = Calendar.autoupdatingCurrent
    if calendar.isDateInToday(dayStart) {
      return NSLocalizedString("Today", comment: "Date separator label")
    }
    if calendar.isDateInYesterday(dayStart) {
      return NSLocalizedString("Yesterday", comment: "Date separator label")
    }
    return dayStart.formatted(date: .abbreviated, time: .omitted)
  }
}

final class CollapsedHistoryTableCell: NSView {
  static let height: CGFloat = 34

  private let label = NSTextField(labelWithString: NSLocalizedString("Cleared", comment: "Collapsed history row"))
  private var onClick: (() -> Void)?
  private var trackingArea: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 12, weight: .regular)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(didClickLabel)))
    addSubview(label)

    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -4),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(onClick: @escaping () -> Void) {
    self.onClick = onClick
  }

  override func updateTrackingAreas() {
    if let trackingArea {
      label.removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: label.bounds,
      options: [.mouseEnteredAndExited, .activeInActiveApp],
      owner: self,
      userInfo: nil
    )
    label.addTrackingArea(area)
    trackingArea = area
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    label.textColor = .labelColor
  }

  override func mouseExited(with event: NSEvent) {
    label.textColor = .secondaryLabelColor
  }

  @objc private func didClickLabel() {
    onClick?()
  }
}

extension MessageListAppKit: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    chatRows.rowCount
  }
}

extension MessageListAppKit: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    let allowed = chatRows.canSelect(row: row)
    MessageGestureTrace.trace("MessageList.shouldSelectRow row=\(row) allow=\(allowed)")
    return allowed
  }

  private static let rowViewIdentifier = NSUserInterfaceItemIdentifier("MessageListRowView")

  /// AppKit's own row view clips to its bounds, and a sending photo's upload bar draws just
  /// below its row, in the list's bottom inset.
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    if let rowView = tableView.makeView(withIdentifier: Self.rowViewIdentifier, owner: nil) as? NSTableRowView {
      return rowView
    }
    let rowView = NSTableRowView()
    rowView.identifier = Self.rowViewIdentifier
    rowView.clipsToBounds = false
    return rowView
  }

  func isFirstInGroup(at row: Int) -> Bool {
    guard let stableId = messageStableId(forRow: row) else { return true }
    guard let index = chatRows.messageIndex(forStableMessageId: stableId) else { return true }
    guard index > 0 else { return true }

    let current = messages[index]
    let previous = messages[index - 1]
    return !canGroup(previous, current)
  }

  func isLastInGroup(at row: Int) -> Bool {
    guard let stableId = messageStableId(forRow: row) else { return true }
    guard let index = chatRows.messageIndex(forStableMessageId: stableId) else { return true }
    guard index < messages.count - 1 else { return true }

    let current = messages[index]
    let next = messages[index + 1]
    return !canGroup(current, next)
  }

  func isLastMessage(at row: Int) -> Bool {
    guard let stableId = messageStableId(forRow: row) else { return false }
    guard let index = chatRows.messageIndex(forStableMessageId: stableId) else { return false }
    return index == messages.count - 1
  }

  func isFirstMessage(at row: Int) -> Bool {
    guard let stableId = messageStableId(forRow: row) else { return false }
    guard let index = chatRows.messageIndex(forStableMessageId: stableId) else { return false }
    return index == 0
  }

  private func startsAfterDaySeparator(row: Int) -> Bool {
    guard row > 0 else { return false }
    if case .daySeparator? = rowItem(at: row - 1) {
      return true
    }
    return false
  }

  private func isRTLMessage(_ message: FullMessage?) -> Bool {
    guard let text = message?.displayText else { return false }
    for scalar in text.unicodeScalars {
      if CharacterSet.whitespacesAndNewlines.contains(scalar)
        || CharacterSet.punctuationCharacters.contains(scalar)
        || CharacterSet.symbols.contains(scalar)
        || CharacterSet.decimalDigits.contains(scalar)
      {
        continue
      }

      if isRTLScalar(scalar) {
        return true
      }

      if scalar.properties.isAlphabetic {
        return false
      }
    }

    return false
  }

  private func isRTLScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
      case 0x0590 ... 0x08FF,
           0xFB1D ... 0xFDFF,
           0xFE70 ... 0xFEFF,
           0x1_0800 ... 0x1_0FFF:
        true
      default:
        false
    }
  }

  private func makeMessageCell(
    tableView: NSTableView,
    stableId: Int64,
    row: Int
  ) -> NSView? {
    madeMessageCellCount += 1
    let shouldSignpost = madeMessageCellCount <= 160
    let signpostID = OSSignpostID(log: Self.signpostLog)
    if shouldSignpost {
      os_signpost(
        .begin,
        log: Self.signpostLog,
        name: "MessageCellMake",
        signpostID: signpostID,
        "%{public}s",
        "count=\(madeMessageCellCount) row=\(row)"
      )
    }
    defer {
      if shouldSignpost {
        os_signpost(.end, log: Self.signpostLog, name: "MessageCellMake", signpostID: signpostID)
      }
    }

    guard let messageAndIndex = messageAndIndex(forStableId: stableId) else { return nil }
    let message = messageAndIndex.message

    let identifier = NSUserInterfaceItemIdentifier("MessageCell")
    let reusedView = tableView.makeView(withIdentifier: identifier, owner: nil)
    let cell = reusedView as? MessageTableCell ?? MessageTableCell()
    cell.identifier = identifier
    cell.setDependencies(dependencies)
    cell.setAvatarSwipeProvider { [weak self] sourceView in
      if self?.messageQuickActionsView?.isHidden == false {
        self?.clearHoveredMessage()
      }
      return self?.avatarOverlayView.grabAvatar(overlapping: sourceView)
    }

    let inputProps = messageProps(for: row)
    let width = measurementWidth(using: tableView, renderStyle: inputProps.renderStyle)
      ?? fallbackMeasurementWidth(renderStyle: inputProps.renderStyle)
    let (_, _, _, layoutPlan) = calculateSize(
      for: message,
      with: inputProps,
      tableWidth: width
    )

    let props = MessageViewProps(
      firstInGroup: inputProps.firstInGroup,
      lastInGroup: inputProps.lastInGroup,
      startsAfterDaySeparator: inputProps.startsAfterDaySeparator,
      isLastMessage: inputProps.isLastMessage,
      isFirstMessage: inputProps.isFirstMessage,
      isRtl: inputProps.isRtl,
      isDM: inputProps.isDM,
      renderStyle: inputProps.renderStyle,
      index: messageAndIndex.index,
      translated: inputProps.translated,
      interactionMode: interactionMode(for: row),
      replyThreadTitle: inputProps.replyThreadTitle,
      usesAvatarOverlay: usesAvatarOverlay(forRow: row),
      layout: layoutPlan
    )

    cell.setScrollState(scrollState)
    cell.configure(with: message, props: props, animate: animateUpdates && NSAnimationContext.current.duration > 0)
    configureForwardSelection(cell, row: row)
    configureReplyThreadSourceHighlight(cell, row: row)
    let shouldHover = shouldHoverMessageCell(cell, stableId: stableId)
    cell.setMessageHoverState(shouldHover)
    if shouldHover {
      setHoveredMessage(stableId: stableId, cell: cell, force: true)
    }
    if usesAvatarOverlay {
      avatarOverlayNeedsRaise = true
    }
    return cell
  }

  var animateUpdates: Bool {
    // don't animate initial layout
    !needsInitialScroll
  }

  /// ceil'ed table width.
  /// ceiling prevent subpixel differences in height calc passes which can cause jitter
  private func tableWidth() -> CGFloat {
    measurementWidth() ?? rawMeasurementWidth(using: tableView)
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let item = rowItem(at: row) else { return nil }

    #if DEBUG
    log.trace("Making/using view for row \(row)")
    #endif

    switch item {
      case let .daySeparator(dayStart):
        let identifier = NSUserInterfaceItemIdentifier("DateSeparatorCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? DateSeparatorTableCell
          ?? DateSeparatorTableCell()
        cell.identifier = identifier
        cell.configure(dayStart: dayStart)
        return cell

      case .unreadSeparator:
        let identifier = NSUserInterfaceItemIdentifier("UnreadSeparatorCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? UnreadSeparatorTableCell
          ?? UnreadSeparatorTableCell()
        cell.identifier = identifier
        cell.configure(text: NSLocalizedString("Unread messages", comment: "Unread separator label"))
        return cell

      case .repliesSeparator:
        let identifier = NSUserInterfaceItemIdentifier("RepliesSeparatorCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? UnreadSeparatorTableCell
          ?? UnreadSeparatorTableCell()
        cell.identifier = identifier
        cell.configure(
          text: NSLocalizedString("Replies", comment: "Reply thread separator label"),
          showsBackground: false
        )
        return cell

      case .statusNotice:
        let identifier = NSUserInterfaceItemIdentifier("StatusNoticeCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? StatusNoticeTableCell
          ?? StatusNoticeTableCell()
        cell.identifier = identifier
        cell.configure(text: chatRows.statusNotice ?? "")
        return cell

      case .collapsedHistory:
        let identifier = NSUserInterfaceItemIdentifier("CollapsedHistoryCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? CollapsedHistoryTableCell
          ?? CollapsedHistoryTableCell()
        cell.identifier = identifier
        cell.configure { [weak self] in
          Task { @MainActor [weak self] in
            guard let self else { return }
            do {
              try await collapseHistory(maxID: nil)
            } catch {
              log.error("Failed to show collapsed history", error: error)
              ToastCenter.shared.showError(error.localizedDescription)
            }
          }
        }
        return cell

      case .parentMessage:
        guard let id = messageStableId(forRow: row) else { return nil }
        return makeMessageCell(tableView: tableView, stableId: id, row: row)

      case let .message(id):
        return makeMessageCell(tableView: tableView, stableId: id, row: row)
    }
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    guard let item = rowItem(at: row) else {
      return defaultRowHeight
    }
    rowHeightQueryCount += 1
    let shouldSignpost = rowHeightQueryCount <= 200
    let signpostID = OSSignpostID(log: Self.signpostLog)
    if shouldSignpost {
      os_signpost(
        .begin,
        log: Self.signpostLog,
        name: "MessageRowHeight",
        signpostID: signpostID,
        "%{public}s",
        "count=\(rowHeightQueryCount) row=\(row)"
      )
    }
    defer {
      if shouldSignpost {
        os_signpost(.end, log: Self.signpostLog, name: "MessageRowHeight", signpostID: signpostID)
      }
    }

    #if DEBUG
    log.trace("Noting height change for row \(row)")
    #endif

    switch item {
      case .daySeparator:
        return DateSeparatorTableCell.height

      case .unreadSeparator:
        return UnreadSeparatorTableCell.height

      case .repliesSeparator:
        return UnreadSeparatorTableCell.height

      case .collapsedHistory:
        return CollapsedHistoryTableCell.height

      case .statusNotice:
        return StatusNoticeTableCell.height

      case let .message(id), let .parentMessage(id):
        guard let message = messageAndIndex(forStableId: id)?.message else { return defaultRowHeight }
        let props = messageProps(for: row)
        guard let width = measurementWidth(using: tableView, renderStyle: props.renderStyle) else {
          return getCachedSize(forRow: row)?.height ?? defaultRowHeight
        }
        let (_, _, _, plan) = calculateSize(
          for: message,
          with: props,
          tableWidth: width
        )

        return plan.totalHeight
    }
  }
}

extension NSTableView {
  func scrollToBottomWithInset(cancel: Bool = false) {
    guard let scrollView = enclosingScrollView,
          numberOfRows > 0 else { return }

    // Get the bottom inset value
    let bottomInset = scrollView.contentInsets.bottom

    // Calculate the point that includes the bottom inset
    let maxVisibleY = scrollView.documentView?.bounds.maxY ?? 0
    let targetPoint = NSPoint(
      x: 0,
      y: maxVisibleY + bottomInset - scrollView.contentView.bounds.height
    )

    // scrollView.documentView?.scroll(targetPoint)

    scrollView.contentView.updateBounds(targetPoint, cancel: cancel)

    // Ensure the last row is visible
    // let lastRow = numberOfRows - 1
    // scrollRowToVisible(lastRow)
  }
}

extension Notification.Name {
  static let messageListScrollStateDidChange = Notification.Name("messageListScrollStateDidChange")
}

enum MessageListScrollState {
  case scrolling
  case idle

  var isScrolling: Bool {
    self == .scrolling
  }
}

extension MessageListAppKit {
  // MARK: - Scroll to message

  func scrollToMsgAndHighlight(_ request: ScrollToMessageRequest) {
    releaseReadingHold()
    readingPlaceCaptureBlocked = false
    targetScrollRevision &+= 1
    isProgrammaticScroll = false
    targetScrollTask?.cancel()
    targetScrollTask = nil
    pendingArrivalMessageID = nil
    guard request.messageId > 0, !isDisposed else { return }
    if messages.contains(where: { $0.message.messageId == request.messageId }),
       chatRows.historyCoverage.isCertifiedMessage(request.messageId)
    {
      scrollToMessage(
        request.messageId,
        shouldHighlight: true,
        quote: request.quote,
        flashesRow: request.reason == .search
      )
      return
    }

    let peer = peerId
    let limit = MessagesProgressiveViewModel.defaultInitialLimit()
    targetScrollTask = Task { @MainActor [weak self] in
      do {
        let outcome = try await MessageHistoryRepairCoordinator.shared.loadAround(
          peer: peer,
          anchorID: request.messageId,
          limit: limit
        )
        guard let self, !Task.isCancelled, !isDisposed else { return }
        let newestLoadedID = messages.lazy.map(\.message.messageId).max() ?? 0
        if chatRows.historyCoverage.isAtCertifiedLiveEnd, request.messageId > newestLoadedID {
          // A pushed message can precede sync. Stay on the live end and focus
          // the row when the update that delivers it is applied.
          pendingArrivalMessageID = request.messageId
          scrollToBottom(animated: true)
          return
        }
        loadBatchTask?.cancel()
        loadBatchTask = nil
        remoteNewerTask?.cancel()
        guard outcome != .empty, chatRows.loadLocalWindowAroundMessage(
          messageId: request.messageId,
          publish: false
        ) else {
          ToastCenter.shared.showError("Could not load that message")
          return
        }
        rebuildRowItems()
        clearHoveredMessage()
        tableView.reloadData()
        pruneMessageSelection()
        scheduleMessageHoverRefresh()
        await Task.yield()
        guard !Task.isCancelled, !isDisposed else { return }
        guard let displayedMessageID = nearestDisplayedMessageID(to: request.messageId) else {
          ToastCenter.shared.showError("Could not load that message")
          return
        }
        scrollToMessage(
          displayedMessageID,
          shouldHighlight: displayedMessageID == request.messageId,
          quote: request.quote,
          flashesRow: request.reason == .search
        )
        // Landing on the newest row below the target is the ordinary latest
        // view, not a detour worth announcing.
        if displayedMessageID != request.messageId,
           !(displayedMessageID < request.messageId && displayedMessageID == messages.lazy.map(\.message.messageId).max())
        {
          ToastCenter.shared.showInfo("Message unavailable. Showing nearby history.")
        }
      } catch is CancellationError {
        return
      } catch {
        guard let self, !Task.isCancelled, !isDisposed else { return }
        log.error("Failed to load history for message focus", error: error)
        ToastCenter.shared.showError("Could not load that message")
      }
    }
  }

  private func nearestDisplayedMessageID(to coordinate: Int64) -> Int64? {
    let messageIDs = messages.lazy.map(\.message.messageId).filter { $0 > 0 }
    if messageIDs.contains(coordinate) {
      return coordinate
    }
    let neighbor = messageIDs.filter { $0 > coordinate }.min()
      ?? messageIDs.filter { $0 < coordinate }.max()
    return neighbor.flatMap {
      chatRows.historyCoverage.isCertifiedContinuation(between: coordinate, and: $0) ? $0 : nil
    }
  }

  /// `flashesRow` also tints the whole row when the quoted text is highlighted, so a search
  /// match stands out in a long or busy chat.
  private func scrollToMessage(
    _ msgId: Int64,
    shouldHighlight: Bool,
    quote: String? = nil,
    flashesRow: Bool = false
  ) {
    let revision = targetScrollRevision
    guard let messageIndex = messages.firstIndex(where: { $0.message.messageId == msgId }) else {
      return
    }

    let stableId = messages[messageIndex].id
    guard let row = chatRows.rowIndex(forMessageStableId: stableId) else {
      log.error("Row not found for stable message id \(stableId)")
      ToastCenter.shared.showError("Could not load that message")
      return
    }

    // Get current scroll position and target position
    let currentY = scrollView.contentView.bounds.origin.y
    let targetRect = tableView.rect(ofRow: row)
    let viewportHeight = scrollView.contentView.bounds.height
    var targetY = max(0, targetRect.midY - (viewportHeight / 2))

    // Highlighted text aims at its line, which in a long message can be far from its
    // middle. Already in view, it is highlighted where it is.
    if shouldHighlight, let quote,
       let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCell,
       let quoteRect = cell.quoteRect(quote, in: tableView)
    {
      if quoteViewport.contains(quoteRect) {
        cell.highlight(quote: quote, flashesRow: flashesRow)
        return
      }
      targetY = centeredScrollY(for: quoteRect)
    }

    // Calculate distance to scroll
    let distance = abs(targetY - currentY)

    // Prepare for animation
    beginProgrammaticScroll()

    // For long distances, use a two-phase animation
    if distance > viewportHeight * 2 {
      // Phase 1: Quick scroll to get close
      NSAnimationContext.runAnimationGroup { [weak self] context in
        context.duration = 0.3
        context.timingFunction = CAMediaTimingFunction(name: .easeIn)

        // Scroll to a point just before the target
        let intermediateY = targetY > currentY
          ? targetY - viewportHeight / 2
          : targetY + viewportHeight / 2
        self?.scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: intermediateY))
      } completionHandler: { [weak self] in
        guard let self, !isDisposed, targetScrollRevision == revision else { return }
        // Phase 2: Slow down for final approach
        NSAnimationContext.runAnimationGroup { [weak self] context in
          context.duration = 0.4
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)

          // Final scroll to target
          self?.scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
        } completionHandler: { [weak self] in
          guard let self, !isDisposed, targetScrollRevision == revision else { return }
          // Clean up
          endProgrammaticScroll()
          updateUnreadIfNeeded()

          if shouldHighlight,
             let currentRow = chatRows.rowIndex(forMessageStableId: stableId)
          {
            highlightMessage(at: currentRow, quote: quote, flashesRow: flashesRow)
          }
        }
      }
    } else {
      // For short distances, use a single smooth animation
      NSAnimationContext.runAnimationGroup { [weak self] context in
        context.duration = 0.4
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        self?.scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
      } completionHandler: { [weak self] in
        guard let self, !isDisposed, targetScrollRevision == revision else { return }
        // Clean up
        endProgrammaticScroll()
        updateUnreadIfNeeded()

        if shouldHighlight,
           let currentRow = chatRows.rowIndex(forMessageStableId: stableId)
        {
          highlightMessage(at: currentRow, quote: quote, flashesRow: flashesRow)
        }
      }
    }
  }

  private func highlightMessage(at row: Int, quote: String? = nil, flashesRow: Bool = false) {
    // Verify row is still valid (tableView state may have changed during animation)
    guard row >= 0, row < tableView.numberOfRows else {
      log.trace("Cannot highlight message at row \(row) - tableView has \(tableView.numberOfRows) rows")
      return
    }

    guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCell else {
      return
    }
    // A row that was off screen is centered as a whole; in a tall message the highlighted line
    // can still be out of view, so bring it in before highlighting it.
    if let quote, let quoteRect = cell.quoteRect(quote, in: tableView), !quoteViewport.contains(quoteRect) {
      let revision = targetScrollRevision
      beginProgrammaticScroll()
      NSAnimationContext.runAnimationGroup { [weak self] context in
        guard let self else { return }
        context.duration = 0.25
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: centeredScrollY(for: quoteRect)))
      } completionHandler: { [weak self] in
        guard let self, !isDisposed, targetScrollRevision == revision else { return }
        endProgrammaticScroll()
        updateUnreadIfNeeded()
        cell.highlight(quote: quote, flashesRow: flashesRow)
      }
      return
    }
    cell.highlight(quote: quote, flashesRow: flashesRow)
  }

  /// The part of the list not covered by the header and compose bar, in table coordinates.
  private var quoteViewport: CGRect {
    let bounds = scrollView.contentView.bounds
    let insets = scrollView.contentInsets
    return CGRect(
      x: bounds.minX,
      y: bounds.minY + insets.top,
      width: bounds.width,
      height: max(0, bounds.height - insets.top - insets.bottom)
    )
  }

  /// Scroll position that centers `rect` in the uncovered part of the list.
  private func centeredScrollY(for rect: CGRect) -> CGFloat {
    let bounds = scrollView.contentView.bounds
    let insets = scrollView.contentInsets
    let visibleHeight = bounds.height - insets.top - insets.bottom
    let proposed = NSRect(
      origin: NSPoint(x: bounds.minX, y: rect.midY - insets.top - visibleHeight / 2),
      size: bounds.size
    )
    return scrollView.contentView.constrainBoundsRect(proposed).origin.y
  }
}

extension MessageListAppKit {
  /// Scrolls to a specific row index with a two-phase animation for distant targets
  /// - Parameters:
  ///   - index: The row index to scroll to
  ///   - position: Where in the viewport to position the row (default: center)
  ///   - animated: Whether to animate the scroll
  func scrollToIndex(_ index: Int, position: ScrollPosition = .center, animated: Bool = true) {
    guard index >= 0, index < tableView.numberOfRows else {
      log.error("Invalid index to scroll to: \(index)")
      return
    }

    // Get current scroll position and target position
    let currentY = scrollView.contentView.bounds.origin.y
    let targetRect = tableView.rect(ofRow: index)
    let viewportHeight = scrollView.contentView.bounds.height

    // Account for bottom insets
    let bottomInset = scrollView.contentInsets.bottom
    let effectiveViewportHeight = viewportHeight - bottomInset

    // Calculate target Y based on desired position
    let targetY: CGFloat = switch position {
      case .top:
        max(0, targetRect.minY - 8) // Small padding from top
      case .center:
        // Center in the effective viewport (accounting for bottom inset)
        max(0, targetRect.midY - (effectiveViewportHeight / 2))
      case .bottom:
        // Position at bottom of effective viewport
        max(0, targetRect.maxY - effectiveViewportHeight + 8)
    }

    // If not animated, just jump to position
    if !animated {
      beginProgrammaticScroll()
      defer { endProgrammaticScroll() }
      scrollView.withoutScrollerFlash { [weak self] in
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self?.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: targetY))
        CATransaction.commit()
      }
      return
    }

    // Calculate distance to scroll
    let distance = abs(targetY - currentY)

    // Prepare for animation
    beginProgrammaticScroll()

    // For long distances, use a two-phase animation
    if distance > viewportHeight * 2 {
      // Phase 1: Quick scroll to get close
      hideScrollbars()

      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.0

        // Scroll to a point just before the target
        let intermediateY = targetY > currentY
          ? targetY - viewportHeight / 2
          : targetY + viewportHeight / 2
        scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: intermediateY))
      } completionHandler: {
        // Phase 2: Slow down for final approach
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.3
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)

          // Final scroll to target
          self.scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
        } completionHandler: { [weak self] in
          // Clean up
          self?.endProgrammaticScroll()

          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.enableScrollbars()
          }
        }
      }
    } else {
      // For short distances, use a single smooth animation
      hideScrollbars()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.3
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
      } completionHandler: { [weak self] in
        // Clean up
        self?.endProgrammaticScroll()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
          self?.enableScrollbars()
        }
      }
    }
  }

  /// Define scroll position options
  enum ScrollPosition {
    case top
    case center
    case bottom
  }
}

extension MessageListAppKit {
  func dispose() {
    // The controller is rebuilt on every navigation, so leaving the chat ends here. Captured
    // before anything is torn down, while the rows and scroll geometry are still the user's.
    captureReadingPlace()
    isDisposed = true
    cancellables.removeAll()
    clearReplyThreadSourceAnchor()

    // Cancel any tasks
    eventMonitorTask?.cancel()
    eventMonitorTask = nil
    integrationCheckTask?.cancel()
    integrationCheckTask = nil
    remoteOlderTask?.cancel()
    remoteOlderTask = nil
    remoteNewerTask?.cancel()
    remoteNewerTask = nil
    targetScrollTask?.cancel()
    targetScrollTask = nil
    unreadFetchTask?.cancel()
    unreadFetchTask = nil
    unreadFetchConnection = nil
    loadBatchTask?.cancel()
    loadBatchTask = nil
    heightPrecalcTask?.cancel()
    heightPrecalcTask = nil
    mediaWarmupTask?.cancel()
    mediaWarmupTask = nil
    let thumbnailWarmups = mediaWarmups
    mediaWarmups.removeAll()
    Task {
      for warmup in thumbnailWarmups {
        await InlineTinyThumbnailPrewarmer.cancel(warmup)
      }
    }
    deferredTranslationTask?.cancel()
    deferredTranslationTask = nil
    toolbarDisplayModeObservation?.invalidate()
    toolbarDisplayModeObservation = nil
    observedToolbar = nil
    avatarOverlaySyncInProgress = false
    avatarOverlaySyncPending = false
    clearHoveredMessage()
    removeMessageHoverTracking()
    if usesAvatarOverlay {
      avatarOverlayView.clearAvatars()
    }

    // Remove all observers
    removeLiveResizeObserver()
    NotificationCenter.default.removeObserver(self)
    if let appActivityObserverId {
      AppActivityMonitor.shared.removeObserver(appActivityObserverId)
      self.appActivityObserverId = nil
    }

    // Clear all callbacks
    scrollToBottomButton.onClick = nil
    activityJumpButton.onClick = nil
    activityJumpButton.onMarkAllRead = nil
    reactionJumpButton.onClick = nil
    reactionJumpButton.onMarkAllRead = nil
    activityNavigator?.stop()
    activityNavigator = nil
    onMessageSelectionChange = nil

    // Dispose view model
    chatRows.dispose()

    // Clear table view delegates
    tableView.delegate = nil
    tableView.dataSource = nil

    // Remove from parent if still attached
    view.removeFromSuperview()
    removeFromParent()

    log.trace("MessageListAppKit disposed: \(self)")
  }
}

private extension MessagesProgressiveViewModel.MessagesChangeSet {
  var traceLabel: String {
    switch self {
      case .added:
        "added"
      case .updated:
        "updated"
      case .deleted:
        "deleted"
      case .reload:
        "reload"
    }
  }
}
