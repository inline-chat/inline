import AppKit
import Combine
import InlineKit
import InlineMacUI
import InlineUI
import Logger
import os.signpost
import SwiftUI
import Throttler
import Translation

/// Experimental fork: retain the interaction scaffold while validating independent
/// window and geometry policies. Cells and the shared history cache remain canonical.
final class ExperimentalMessageListAppKit: NSViewController, ChatMessageListController {
  // Data
  private var dependencies: AppDependencies
  private var peerId: Peer
  private var chat: Chat?
  private var chatId: Int64 {
    chat?.id ?? 0
  }

  private let initialPosition: MessageListInitialPosition
  private let requestedMessageID: Int64?
  private let positionAccountID: Int64?
  private var lastSavedPosition: MessageListInitialPosition?
  private var isCommittingGeometry = false
  private var geometryAnchor: VisibleMessageAnchor?
  private var pendingRichLayoutIDs = Set<Int64>()
  private var richLayoutRefreshScheduled = false
  var preservesHistoryOnSend: Bool {
    true
  }

  private let chatRows: ExperimentalChatRowListViewModel
  private let showUnreadAfter: Int64?
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

  private let log = Log.scoped("ExperimentalMessageListAppKit")
  private let sizeCalculator = MessageSizeCalculator()
  private let defaultRowHeight: CGFloat = 45.0

  private static let signpostLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")
  private var madeMessageCellCount = 0
  private var rowHeightQueryCount = 0
  private var anchorRestoreCount = 0
  private var didScheduleChatNavigationReady = false

  private let minimumAvailableMeasurementWidth: CGFloat = 80
  private var lastValidMeasurementWidth: CGFloat = 0
  private var lastKnownWidth: CGFloat = 0
  private var didFinalizeInitialMeasurementWidth = false

  private var eventMonitorTask: Task<Void, Never>?
  private var integrationCheckTask: Task<Void, Never>?
  private var remoteOlderTask: Task<Void, Never>?
  private var remoteNewerTask: Task<Void, Never>?
  private var historyGapTask: Task<Void, Never>?
  private var loadingHistoryGap: ExperimentalChatRowListViewModel.Row?
  private var attemptedHistoryGap: ExperimentalChatRowListViewModel.Row?
  private var lastRemoteNewerAttempt: (messageID: Int64, date: Date)?
  private var targetScrollTask: Task<Void, Never>?
  private var discreteScrollEndTask: Task<Void, Never>?
  private var targetScrollRevision: UInt64 = 0
  private var loadBatchTask: Task<Void, Never>?
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

  init(
    dependencies: AppDependencies,
    peerId: Peer,
    chat: Chat,
    showUnreadAfter: Int64? = nil,
    initialState: MessagesProgressiveViewModel.InitialState? = nil,
    initialPosition: MessageListInitialPosition = .latest,
    requestedMessageID: Int64? = nil,
    collapsedMaxId: Int64? = nil,
    initialPinnedMessage: PreparedPinnedMessage? = nil,
    surfaceStyle: ChatViewAppearance.SurfaceStyle = .content,
    additionalTopContentInset: CGFloat = 0
  ) {
    self.initialPosition = initialPosition
    self.requestedMessageID = requestedMessageID
    positionAccountID = dependencies.auth.currentUserId
    self.dependencies = dependencies
    self.peerId = peerId
    self.chat = chat
    self.showUnreadAfter = showUnreadAfter
    self.initialPinnedMessage = initialPinnedMessage
    self.surfaceStyle = surfaceStyle
    self.additionalTopContentInset = additionalTopContentInset
    chatRows = ExperimentalChatRowListViewModel(
      peer: peerId,
      initialState: initialState,
      showUnreadAfter: showUnreadAfter,
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

    isAtBottom = initialPosition.followsLatest
    isAtAbsoluteBottom = initialPosition.followsLatest
    chatRows.setAtBottom(initialPosition.followsLatest)
    if let anchor = initialPosition.messageID { chatRows.setHistoryAnchor(anchor) }

    pinnedHeaderHeight = initialPinnedMessage == nil ? 0 : PinnedMessageHeaderView.preferredHeight

    appActivityObserverId = AppActivityMonitor.shared.addObserver { [weak self] state in
      guard let self else { return }
      guard state == .active else {
        persistReadingPosition()
        return
      }
      lastVisibleReadCandidateID = nil
      updateUnreadIfNeeded()
    }

    sizeCalculator.prepareForUse()
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
        switch event {
          case let .scrollToMsg(request):
            // scroll and highlight
            self_.scrollToMsgAndHighlight(request)

          case .scrollToBottom:
            if !self_.isAtBottom || self_.chatRows.canLoadNewerFromLocal {
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
      sizeCalculator.invalidateCache()
      chatRows.invalidateMeasurements()

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
  private var pinnedHeaderTopConstraint: NSLayoutConstraint?
  private var pinnedHeaderHeightConstraint: NSLayoutConstraint?
  private lazy var pinnedHeaderView: PinnedMessageHeaderView = {
    let view = PinnedMessageHeaderView(
      dependencies: dependencies,
      peerId: peerId,
      chatId: chatId,
      initialPinnedMessage: initialPinnedMessage,
      usesPreparedObservation: true
    )
    view.onHeightChange = { [weak self] height in
      guard let self else { return }
      guard abs(pinnedHeaderHeight - height) > 0.5 else { return }
      let anchor = !needsInitialScroll ? captureVisibleMessageAnchor() : nil
      let wasCommittingGeometry = isCommittingGeometry
      isCommittingGeometry = true
      defer { isCommittingGeometry = wasCommittingGeometry }
      pinnedHeaderHeight = height
      pinnedHeaderHeightConstraint?.constant = height
      updateScrollViewInsets()
      if !needsInitialScroll {
        if isAtAbsoluteBottom { scrollToBottom(animated: false) }
        else if let anchor { restoreVisibleMessageAnchor(anchor) }
      }
    }
    return view
  }()

  private func rebuildRowItems() {
    _ = chatRows.rebuildFromViewModel(showUnreadAfter: showUnreadAfter)
  }

  private func rowItem(at row: Int) -> ExperimentalChatRowListViewModel.Row? {
    chatRows.row(at: row)
  }

  func collapseHistory(maxID: Int64?) async throws {
    let effectiveMaxID = try await Api.realtime.collapseHistory(peer: peerId.toInputPeer(), maxID: maxID)
    setCollapsedMaxId(effectiveMaxID)
  }

  func setCollapsedMaxId(_ collapsedMaxId: Int64?) {
    let wasAtBottom = isViewLoaded && isAtAbsoluteBottom
    let anchor = isViewLoaded ? captureVisibleMessageAnchor() : nil
    guard chatRows.setCollapsedMaxId(collapsedMaxId) != .none, isViewLoaded else { return }

    clearHoveredMessage()
    tableView.reloadData()
    tableView.layoutSubtreeIfNeeded()
    if wasAtBottom {
      scrollToBottom(animated: false)
    } else if let anchor {
      restoreVisibleMessageAnchor(anchor)
    }
    syncAvatarOverlayAfterTableLayout()
    scheduleMediaWarmupForVisibleAndNearby(reason: "collapse_boundary")
  }

  private struct VisibleMessageAnchor {
    let stableId: Int64
    let messageID: Int64
    let offset: CGFloat
  }

  private func captureVisibleMessageAnchor() -> VisibleMessageAnchor? {
    let visibleRect = tableView.visibleRect
    let range = tableView.rows(in: visibleRect)
    guard range.location != NSNotFound, range.length > 0 else { return nil }

    for row in range.location ..< NSMaxRange(range) {
      guard case let .message(stableId) = rowItem(at: row),
            let message = messageAndIndex(forStableId: stableId)?.message,
            message.message.messageId > 0 else { continue }
      if tableView.rect(ofRow: row).maxY <= scrollView.contentView.bounds.minY + scrollView.contentInsets
        .top { continue }
      return VisibleMessageAnchor(
        stableId: stableId,
        messageID: message.message.messageId,
        offset: tableView.rect(ofRow: row).minY - (scrollView.contentView.bounds.minY + scrollView.contentInsets.top)
      )
    }
    return nil
  }

  private func restoreVisibleMessageAnchor(_ anchor: VisibleMessageAnchor) {
    let stableID = chatRows.rowIndex(forMessageStableId: anchor.stableId) != nil ? anchor.stableId
      : nearestDisplayedMessageID(to: anchor.messageID).flatMap { id in
        guard chatRows.historyCoverage.isCertifiedContinuation(between: anchor.messageID, and: id) else { return nil }
        return messages.first(where: { $0.message.messageId == id })?.id
      }
    guard let stableID, let row = chatRows.rowIndex(forMessageStableId: stableID) else { return }
    let rect = tableView.rect(ofRow: row)
    let offset = stableID == anchor.stableId ? min(-anchor.offset, max(0, rect.height - 1)) : 0
    let target = rect.minY + offset - scrollView.contentInsets.top
    let clampedTarget = clampScrollOffset(target)
    scrollView.contentView.updateBounds(NSPoint(x: 0, y: clampedTarget), cancel: true)
    #if DEBUG
    anchorRestoreCount += 1
    if anchorRestoreCount <= 200 {
      let drift = abs(scrollView.contentView.bounds.minY - clampedTarget)
      os_signpost(
        .event, log: Self.signpostLog, name: "MessageListAnchorRestore",
        "%{public}s",
        "drift_pt=\(drift) clamped_pt=\(abs(target - clampedTarget)) rows=\(tableView.numberOfRows)"
      )
    }
    #endif
  }

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
    messages.map(\.id)
  }

  private func selectableStableId(forRow row: Int) -> Int64? {
    guard chatRows.canSelect(row: row) else { return nil }
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

    return table
  }()

  private lazy var scrollView: ExperimentalMessageListScrollView = {
    let scroll = ExperimentalMessageListScrollView()
    scroll.willScrollFromInput = { [weak self] in self?.scrollWheelBegan() }
    scroll.didScrollFromInput = { [weak self] isDiscrete in
      guard let self else { return }
      handleBoundsChange()
      if isDiscrete {
        discreteScrollEndTask = Task { @MainActor [weak self] in
          do { try await Task.sleep(for: .milliseconds(150)) }
          catch { return }
          self?.scrollWheelEnded()
        }
      }
    }
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
    scroll.automaticallyAdjustsContentInsets = false

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
  private lazy var scrollToBottomButton: ScrollToBottomButtonHostingView = {
    let scrollToBottomButton = ScrollToBottomButtonHostingView()
    scrollToBottomButton.onClick = { [weak self] in
      guard let weakSelf = self else { return }
      weakSelf.scrollToNewestAvailable(animated: true)
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
    enableScrollbars()

    log.trace("viewDidLoad for chat \(chatId)")

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
    guard inset.isFinite, abs(insetForCompose - max(0, inset)) > 0.5 else { return }
    let anchor = !needsInitialScroll ? captureVisibleMessageAnchor() : nil
    let wasCommittingGeometry = isCommittingGeometry
    isCommittingGeometry = true
    defer { isCommittingGeometry = wasCommittingGeometry }
    insetForCompose = max(0, inset)
    updateScrollViewInsets()
    scrollToBottomBottomConstraint.constant = -(Theme.messageListBottomInset + insetForCompose)
    if !needsInitialScroll {
      if isAtAbsoluteBottom { scrollToBottom(animated: animate) }
      else if let anchor { restoreVisibleMessageAnchor(anchor) }
    }
    scheduleAvatarOverlaySync()
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
  }

  private func updateToolbarBackgroundForStyleChange() {
    guard isViewLoaded else { return }
    updateScrollViewInsets()
    view.needsLayout = true
  }

  /// This fixes the issue with the toolbar messing up initial content insets on window open. Now we call it on did
  /// layout and it fixes the issue.
  private func updateScrollViewInsets() {
    guard let window = view.window else { return }

    let windowFrame = window.frame
    let contentFrame = window.contentLayoutRect
    let chromeHeight = windowFrame.height - contentFrame.height
    let toolbarHeight = chromeHeight
    self.toolbarHeight = toolbarHeight
    toolbarBgHeightConstraint?.constant = toolbarHeight
    let topInset = toolbarHeight + additionalTopContentInset + pinnedHeaderHeight

    pinnedHeaderTopConstraint?.constant = toolbarHeight + additionalTopContentInset
    pinnedHeaderHeightConstraint?.constant = pinnedHeaderHeight

    let bottomInset = Theme.messageListBottomInset + insetForCompose
    guard abs(scrollView.contentInsets.top - topInset) > 0.5 ||
      abs(scrollView.contentInsets.bottom - bottomInset) > 0.5 else { return }
    let ownsGeometry = !isCommittingGeometry && !needsInitialScroll && !isProgrammaticScroll
    let anchor = ownsGeometry ? captureVisibleMessageAnchor() : nil
    if ownsGeometry { isCommittingGeometry = true }
    scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
    scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: -Theme.messageListBottomInset, right: 0)
    if ownsGeometry {
      if isAtAbsoluteBottom { scrollToBottom(animated: false) }
      else if let anchor { restoreVisibleMessageAnchor(anchor) }
      isCommittingGeometry = false
    }
  }

  private func clampScrollOffset(_ offset: CGFloat) -> CGFloat {
    MessageListViewportGeometry.clampedOffset(
      offset, contentHeight: Double(scrollView.documentView?.bounds.height ?? 0),
      viewportHeight: scrollView.contentView.bounds.height,
      topInset: scrollView.contentInsets.top, bottomInset: scrollView.contentInsets.bottom
    )
  }

  private func isAtTop() -> Bool {
    let scrollOffset = scrollView.contentView.bounds.origin
    let topOffset = min(-scrollView.contentInsets.top, 0)
    return scrollOffset.y <= topOffset + 0.5
  }

  private func userVisibleRect() -> NSRect {
    // Color sampling is needed only for pixels the user can see. The previous
    // expansion included rows behind both toolbar/compose and an extra margin.
    scrollView.effectiveVisibleRect()
  }

  private func updateMessageViewColors() {
    guard messageRenderStyle == .bubble else { return }
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
      pinnedHeaderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      pinnedHeaderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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

    NSLayoutConstraint.activate([
      scrollToBottomButton.trailingAnchor.constraint(
        equalTo: view.trailingAnchor,
        constant: -14
      ),
      scrollToBottomBottomConstraint,
      scrollToBottomButton.widthAnchor.constraint(equalToConstant: Theme.scrollButtonSize),
      scrollToBottomButton.heightAnchor.constraint(equalToConstant: Theme.scrollButtonSize),
    ])
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

    let earlierID = earlier.message.messageId
    let laterID = later.message.messageId
    if earlierID > 0, laterID > 0,
       !chatRows.isCertifiedHistoryContinuation(between: earlierID, and: laterID)
    {
      return false
    }

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
            x: Theme.messageSidePadding,
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

  private func updateColumnWidth(commit: Bool = false) {
    let newWidth = scrollView.contentSize.width
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
    let viewWidth = isViewLoaded ? view.bounds.width : 0
    let widths: [CGFloat] = [
      // Do not touch `self.scrollView` here: AppKit can ask row heights while `scrollView` is still being built.
      tableView.enclosingScrollView?.contentSize.width ?? 0,
      tableView.bounds.width,
      tableView.tableColumns.first?.width ?? 0.0,
      viewWidth,
    ]
    return ceil(widths.first(where: { $0 > 0 }) ?? 0)
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
    guard !isDisposed, !needsInitialScroll else { return }
    targetScrollRevision &+= 1
    let revision = targetScrollRevision
    targetScrollTask?.cancel()
    targetScrollTask = nil
    scrollView.cancelAnimatedScroll()
    discreteScrollEndTask?.cancel()
    discreteScrollEndTask = nil
    isUserScrolling = false
    isProgrammaticScroll = false
    cancelPendingPages()
    // Start a loaded-tail movement immediately. Still refresh local rows below:
    // an optimistic send omitted from history may not have a positive ID yet.
    if chatRows.historyCoverage.isAtCertifiedLiveEnd, !chatRows.canLoadNewerFromLocal {
      isAtBottom = true
      isAtAbsoluteBottom = true
      scrollToBottom(animated: animated)
    }
    targetScrollTask = Task { @MainActor [weak self] in
      guard let self else { return }
      var loadingToast: UUID?
      defer {
        if let loadingToast { ToastCenter.shared.dismiss(loading: loadingToast) }
        if revision == targetScrollRevision {
          targetScrollTask = nil
          requestVisibleHistoryGap()
        }
      }
      do {
        // A historical window's boundary says nothing about whether the tail is
        // already cached. Present the local tail before requesting remote repair.
        guard try await chatRows.loadLatestWindowAsync() else { return }
        guard !Task.isCancelled, !isDisposed, revision == targetScrollRevision else { return }
        if !chatRows.progressiveViewModel.messages.isEmpty {
          commitLatestWindow(animated: animated)
        }
        guard !chatRows.historyCoverage.isAtCertifiedLiveEnd else { return }
        loadingToast = ToastCenter.shared.showLoading("Loading latest messages…")
        _ = try await Api.realtime.send(GetChatHistoryTransaction(peer: peerId, limit: 100))
        guard !Task.isCancelled, !isDisposed, revision == targetScrollRevision else { return }
        guard try await chatRows.loadLatestWindowAsync() else { return }
        guard !Task.isCancelled, !isDisposed, revision == targetScrollRevision else { return }
        commitLatestWindow(animated: animated)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, revision == targetScrollRevision, !isDisposed else { return }
        ToastCenter.shared.showError("Could not load latest messages")
      }
    }
  }

  private func commitLatestWindow(animated: Bool) {
    isCommittingGeometry = true
    defer {
      isCommittingGeometry = false
      scrollToBottomButton.setVisibility(!isAtBottom)
      updateUnreadBadgeVisibility()
      scheduleMessageHoverRefresh()
    }
    if animated, chatRows.messages != chatRows.progressiveViewModel.messages {
      scrollView.captureOutgoingViewport(direction: 1)
    }
    let rowUpdate = chatRows.syncFromViewModelAfterManualMutation()
    clearHoveredMessage()
    if rowUpdate != .none { tableView.reloadData() }
    tableView.layoutSubtreeIfNeeded()
    isAtBottom = chatRows.historyCoverage.isAtCertifiedLiveEnd
    isAtAbsoluteBottom = isAtBottom
    if rowUpdate != .none || !isProgrammaticScroll {
      scrollToBottom(animated: animated)
    }
  }

  private func scrollToBottom(animated: Bool) {
    let target = clampScrollOffset(.greatestFiniteMagnitude)
    beginProgrammaticScroll()
    scrollView.moveViewport(to: target, animated: animated) { [weak self] in
      guard let self, !isDisposed else { return }
      endProgrammaticScroll()
    }
    scheduleAvatarOverlaySync()
  }

  private func setupScrollObserver() {
    // Use direct observation for immediate response
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

    pendingRichLayoutIDs.insert(stableID)
    if isCommittingGeometry {
      guard !richLayoutRefreshScheduled else { return }
      richLayoutRefreshScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self, !isDisposed else { return }
        richLayoutRefreshScheduled = false
        applyPendingRichLayoutChanges()
      }
    } else {
      applyPendingRichLayoutChanges()
    }
  }

  private func applyPendingRichLayoutChanges() {
    guard !isDisposed, !isCommittingGeometry else { return }
    let ids = pendingRichLayoutIDs
    pendingRichLayoutIDs.removeAll(keepingCapacity: true)
    var rows = IndexSet()
    for id in ids {
      chatRows.invalidateMeasurements(for: id)
      rows.formUnion(chatRows.rowIndexes(forMessageStableId: id))
    }
    guard let lastRow = rows.last, lastRow < tableView.numberOfRows else { return }

    let anchor = captureVisibleMessageAnchor()
    let followsLatest = isAtAbsoluteBottom && !isUserScrolling
    isCommittingGeometry = true
    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = 0
    tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
    tableView.noteHeightOfRows(withIndexesChanged: rows)
    tableView.layoutSubtreeIfNeeded()
    if followsLatest { scrollToBottom(animated: false) }
    else if let anchor { restoreVisibleMessageAnchor(anchor) }
    NSAnimationContext.endGrouping()
    isCommittingGeometry = false
    scheduleAvatarOverlaySync()
    refreshMessageHoverAfterGeometryChange()
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

  @objc private func scrollWheelBegan() {
    discreteScrollEndTask?.cancel()
    discreteScrollEndTask = nil
    guard !isDisposed, !isUserScrolling else { return }
    log.trace("scroll wheel began")
    targetScrollRevision &+= 1
    targetScrollTask?.cancel()
    targetScrollTask = nil
    geometryAnchor = nil
    scrollView.cancelAnimatedScroll()
    isProgrammaticScroll = false
    isUserScrolling = true
    scrollState = .scrolling
    clearHoveredMessage()
  }

  @objc private func scrollWheelEnded() {
    discreteScrollEndTask?.cancel()
    discreteScrollEndTask = nil
    guard !isDisposed, isUserScrolling else { return }
    log.trace("scroll wheel ended")
    isUserScrolling = false
    scrollState = .idle
    persistReadingPosition()

    DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
      self?.updateUnreadIfNeeded()
      self?.scheduleMediaWarmupForVisibleAndNearby(reason: "scroll_idle")
      self?.scheduleMessageHoverRefresh()
    }
  }

  /// Recalculate heights for all items once resize has ended
  @objc private func liveResizeEnded() {
    guard !isDisposed else { return }
    view.needsLayout = true
    persistReadingPosition()
  }

  /// True while we're changing scroll position programmatically
  private var isProgrammaticScroll = false

  private func beginProgrammaticScroll() {
    isProgrammaticScroll = true
    clearHoveredMessage()
  }

  private func endProgrammaticScroll() {
    isProgrammaticScroll = false
    handleBoundsChange()
    persistReadingPosition()
    scheduleMessageHoverRefresh()
  }

  /// True when user is scrolling via trackpad or mouse wheel
  private var isUserScrolling = false

  /// True when user is at the bottom of the scroll view within a ~0-10px threshold
  private var isAtBottom = true {
    didSet {
      chatRows.setAtBottom(isAtBottom)
    }
  }

  // When exactly at the bottom
  private var isAtAbsoluteBottom = true
  private var lastSeenMessageId: Int64 = 0
  private var hasUnreadSinceScroll = false

  /// This must be true for the whole duration of animation
  private var isPerformingUpdate = false

  private var prevContentSize: CGSize = .zero
  private var prevOffset: CGFloat = 0

  @objc func scrollViewBoundsChanged(notification: Notification) {
    updateMessageViewColors()
    scheduleAvatarOverlaySync(force: false)
    refreshMessageHoverAfterGeometryChange()

    throttle(
      .milliseconds(32),
      identifier: "chat.v2.bounds.\(ObjectIdentifier(self))",
      by: .mainActor,
      option: .default
    ) { [
      weak self
    ] in
      self?.handleBoundsChange()
    }
  }

  func updateToolbarDebounced() {
    if usesToolbarBgView, !fadesToolbarBgView {
      updateToolbar()
    } else if isToolbarVisible == true {
      throttle(
        .milliseconds(100),
        identifier: "chat.v2.toolbar.\(ObjectIdentifier(self))",
        by: .mainActor,
        option: .default
      ) { [
        weak self
      ] in
        self?.updateToolbar()
      }
    } else {
      // bring it back as fast as possible as it looks bad
      updateToolbar()
    }
  }

  private func handleBoundsChange() {
    let scrollOffset = scrollView.contentView.bounds.origin
    let viewportSize = scrollView.contentView.bounds.size
    let contentSize = scrollView.documentView?.frame.size ?? .zero
    let maxScrollableHeight = max(
      -scrollView.contentInsets.top,
      contentSize.height + scrollView.contentInsets.bottom - viewportSize.height
    )
    let currentScrollOffset = scrollOffset.y

    updateToolbarDebounced()

    if needsInitialScroll || isCommittingGeometry || isPerformingUpdate || isProgrammaticScroll {
      // reports inaccurate heights at this point
      return
    }

    // Prevent iaAtBottom false negative when elastic scrolling
    let overScrolledToBottom = currentScrollOffset > maxScrollableHeight
    let prevAtBottom = isAtBottom
    isAtBottom = chatRows.historyCoverage.isAtCertifiedLiveEnd &&
      (overScrolledToBottom || abs(currentScrollOffset - maxScrollableHeight) <= 5.0)
    isAtAbsoluteBottom = chatRows.historyCoverage.isAtCertifiedLiveEnd &&
      (overScrolledToBottom || abs(currentScrollOffset - maxScrollableHeight) <= 0.5)

    // Check if we're approaching the top
    if isUserScrolling, currentScrollOffset < viewportSize.height {
      loadBatch(at: .older)
    }

    if isUserScrolling,
       maxScrollableHeight - currentScrollOffset < viewportSize.height
    {
      loadBatch(at: .newer)
    }

    if prevAtBottom != isAtBottom {
      let shouldShow = !isAtBottom // && messages.count > 0
      scrollToBottomButton.setVisibility(shouldShow)
      if isAtBottom {
        updateUnreadIfNeeded()
        if chatRows.historyCoverage.isAtCertifiedLiveEnd {
          markMessagesSeen()
        }
      } else {
        updateUnreadBadgeVisibility()
      }
    }
    if !isAtBottom, let anchor = captureVisibleMessageAnchor() {
      chatRows.setHistoryAnchor(anchor.messageID)
    }
    requestVisibleHistoryGap()
  }

  private func requestVisibleHistoryGap() {
    guard !isDisposed, isViewLoaded, !needsInitialScroll, !isCommittingGeometry, !isProgrammaticScroll, targetScrollTask == nil, historyGapTask == nil else { return }
    let visible = tableView.rows(in: tableView.visibleRect)
    guard visible.location != NSNotFound, visible.length > 0 else { return }
    for row in visible.location ..< NSMaxRange(visible) {
      if case .historyHole = rowItem(at: row), let gap = rowItem(at: row), gap != attemptedHistoryGap {
        requestHistoryGap(gap)
        return
      }
    }
  }

  private func requestHistoryGap(_ gap: ExperimentalChatRowListViewModel.Row) {
    guard !isDisposed, case let .historyHole(afterID, _) = gap, historyGapTask == nil else { return }
    attemptedHistoryGap = gap
    loadingHistoryGap = gap
    if let anchor = captureVisibleMessageAnchor() { chatRows.setHistoryAnchor(anchor.messageID) }
    refreshHistoryGapViews()
    let peer = peerId
    historyGapTask = Task { @MainActor [weak self] in
      defer {
        self?.historyGapTask = nil
        self?.loadingHistoryGap = nil
        self?.refreshHistoryGapViews()
        self?.requestVisibleHistoryGap()
      }
      do {
        _ = try await MessageHistoryRepairCoordinator.shared.loadNewer(peer: peer, afterID: afterID)
        // GetChatHistoryTransaction owns the single cache publication. The
        // resulting row projection exposes the next interval if this was one page.
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        ToastCenter.shared.showError("Could not load missing messages. Try again.")
      }
    }
  }

  private func refreshHistoryGapViews() {
    guard isViewLoaded, !isDisposed else { return }
    let visible = tableView.rows(in: tableView.visibleRect)
    guard visible.location != NSNotFound, visible.length > 0 else { return }
    for row in visible.location ..< NSMaxRange(visible) {
      (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageHistoryGapView)?
        .setLoading(rowItem(at: row) == loadingHistoryGap)
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
    guard !isDisposed, !isCommittingGeometry else { return }
    view.needsLayout = true
  }

  private var needsInitialScroll = true

  private func hideScrollbars() {
    // Keep native overlay scrollers available during initial scroll positioning.
  }

  private func enableScrollbars() {
    scrollView.hasVerticalScroller = true
    scrollView.verticalScroller?.isHidden = false
    scrollView.verticalScroller?.alphaValue = 1.0
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    guard !isCommittingGeometry, !isDisposed else { return }
    isCommittingGeometry = true
    defer {
      isCommittingGeometry = false
      scheduleAvatarOverlaySync()
      refreshMessageHoverAfterGeometryChange()
    }
    observeToolbarDisplayModeIfNeeded()
    updateColumnWidthAndCommit()
    updateScrollViewInsets()
    guard let width = measurementWidth() else { return }
    if needsInitialScroll {
      finalizeInitialMeasurementWidthIfNeeded(width: width)
      tableView.layoutSubtreeIfNeeded()
      applyPreparedPosition()
      needsInitialScroll = false
      // Geometry is ready without constructing cells at the document origin.
      // Materialize only the prepared viewport, synchronously before display.
      let visibleRows = tableView.rows(in: tableView.visibleRect)
      if visibleRows.location != NSNotFound, visibleRows.length > 0 {
        tableView.reloadData(
          forRowIndexes: IndexSet(integersIn: visibleRows.location ..< NSMaxRange(visibleRows)),
          columnIndexes: IndexSet(integer: 0)
        )
      }
      tableView.layoutSubtreeIfNeeded()
      scrollToBottomButton.setVisibility(!isAtBottom)
      updateUnreadBadgeVisibility()
    } else {
      checkWidthChangeForHeights()
      if !isProgrammaticScroll {
        if isAtAbsoluteBottom {
          scrollToBottom(animated: false)
        } else if let geometryAnchor {
          restoreVisibleMessageAnchor(geometryAnchor)
        }
      }
    }
    geometryAnchor = nil
    updateToolbar()
    scheduleChatNavigationReadyAfterInitialLayout()
  }

  private func applyPreparedPosition() {
    switch initialPosition {
      case .latest:
        scrollToBottom(animated: false)
      case let .anchor(anchor):
        guard let messageID = nearestDisplayedMessageID(to: anchor.messageID),
              let message = messages.first(where: { $0.message.messageId == messageID }),
              let row = chatRows.rowIndex(forMessageStableId: message.id) else { return }
        let offset = messageID == anchor
          .messageID ? min(anchor.offsetY, max(0, tableView.rect(ofRow: row).height - 1)) : 0
        let target = tableView.rect(ofRow: row).minY + offset - scrollView.contentInsets.top
        scrollView.contentView.updateBounds(NSPoint(x: 0, y: clampScrollOffset(target)), cancel: true)
        if let requestedMessageID, messageID != requestedMessageID {
          ToastCenter.shared.showInfo("Message unavailable. Showing nearby history.")
        }
    }
  }

  private func persistReadingPosition() {
    guard isViewLoaded, !needsInitialScroll, !isCommittingGeometry, !isProgrammaticScroll,
          !isPerformingUpdate, view.window?.isKeyWindow == true, let accountID = positionAccountID else { return }
    let position: MessageListInitialPosition
    if isAtAbsoluteBottom, chatRows.historyCoverage.isAtCertifiedLiveEnd {
      position = .latest
    } else {
      guard let anchor = captureVisibleMessageAnchor(),
            let message = messageAndIndex(forStableId: anchor.stableId)?.message,
            let saved = MessageListViewportAnchor(
              messageID: message.message.messageId,
              offsetY: -anchor.offset
            ) else { return }
      position = .anchor(saved)
    }
    guard position != lastSavedPosition else { return }
    lastSavedPosition = position
    let chatID = chatId
    let issuedAt = DispatchTime.now().uptimeNanoseconds
    Task {
      await ExperimentalChatPositionStore.shared.save(
        position,
        accountID: accountID,
        chatID: chatID,
        issuedAt: issuedAt
      )
    }
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
      self?.requestVisibleHistoryGap()
    }
  }

  override func viewWillDisappear() {
    persistReadingPosition()
    super.viewWillDisappear()
    log.trace("viewWillDisappear() called")
  }

  override func viewDidDisappear() {
    persistReadingPosition()
    super.viewDidDisappear()
    log.trace("viewDidDisappear() called")
    removeLiveResizeObserver()
    clearHoveredMessage()
  }

  override func viewWillLayout() {
    if !needsInitialScroll, !isCommittingGeometry, !isPerformingUpdate, !isProgrammaticScroll, geometryAnchor == nil {
      geometryAnchor = captureVisibleMessageAnchor()
    }
    super.viewWillLayout()
    log.trace("viewWillLayout() called")
  }

  private func finalizeInitialMeasurementWidthIfNeeded(width: CGFloat) {
    guard !didFinalizeInitialMeasurementWidth else { return }
    // Expose rows only after the clip view has its final width and insets.
    // AppKit otherwise measures and constructs provisional cells during setup,
    // then repeats that work when the prepared position is committed.
    didFinalizeInitialMeasurementWidth = true
    lastKnownWidth = width
    tableView.reloadData()
  }

  /// All row coordinates must belong to the same width, including offscreen
  /// rows above the anchor. Visible cells reuse the same measured plans.
  private func checkWidthChangeForHeights() {
    guard !needsInitialScroll, let width = measurementWidth(), abs(width - lastKnownWidth) > 0.5 else { return }
    lastKnownWidth = width
    chatRows.invalidateMeasurements()
    let rows = IndexSet(integersIn: 0 ..< tableView.numberOfRows)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      updateHeightsForRows(at: rows, width: width)
      tableView.noteHeightOfRows(withIndexesChanged: rows)
      tableView.layoutSubtreeIfNeeded()
    }
  }

  private var loadingBatch = false
  private var batchRevision: UInt64 = 0
  private var pendingOlderBatch = false
  private var pendingNewerBatch = false

  private func cancelPendingPages() {
    batchRevision &+= 1
    loadBatchTask?.cancel()
    loadBatchTask = nil
    loadingBatch = false
    pendingOlderBatch = false
    pendingNewerBatch = false
    remoteOlderTask?.cancel()
    remoteNewerTask?.cancel()
    historyGapTask?.cancel()
  }

  private func shouldRequestRemoteOlder(beforeMessageId: Int64) -> Bool {
    beforeMessageId > 0 && remoteOlderTask == nil && !chatRows.historyCoverage.hasCertifiedOlderEdge
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

    remoteOlderTask = Task { [weak self] in
      guard let self else { return }
      defer { remoteOlderTask = nil }

      do {
        guard !Task.isCancelled else { return }
        let outcome = try await MessageHistoryRepairCoordinator.shared.loadOlder(
          peer: peerId,
          beforeID: beforeMessageId
        )
        guard !Task.isCancelled else { return }

        guard outcome == .loaded else { return }

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
       Date().timeIntervalSince(attempt.date) < 2 { return }
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
    guard !isDisposed, !needsInitialScroll else { return }
    if loadingBatch {
      if direction == .older { pendingOlderBatch = true }
      else { pendingNewerBatch = true }
      return
    }
    loadingBatch = true
    batchRevision &+= 1
    let revision = batchRevision
    loadBatchTask?.cancel()
    loadBatchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if revision == batchRevision {
          loadBatchTask = nil
          loadingBatch = false
          if pendingOlderBatch {
            pendingOlderBatch = false
            loadBatch(at: .older)
          } else if pendingNewerBatch {
            pendingNewerBatch = false
            loadBatch(at: .newer)
          }
        }
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
      var didInsertRows = false

      log.trace("Loading \(loadDirectionLabel(direction)) batch")
      let didLoadLocalBatch = await chatRows.loadBatchAsync(
        at: direction, publish: false, allowUnavailableLocal: allowUnavailableLocal
      )
      guard !Task.isCancelled, !isDisposed, revision == batchRevision else { return }

      if didLoadLocalBatch {
        let anchor = captureVisibleMessageAnchor()
        if viewModel.messages.count > 400, let anchor {
          _ = try? await chatRows.loadLocalWindowAroundMessageAsync(messageId: anchor.messageID, limit: 400)
          guard !Task.isCancelled, !isDisposed, revision == batchRevision else { return }
        }
        didInsertRows = commitLoadedBatch(anchor: anchor)
      }

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

  /// Keep the synchronous AppKit commit outside the suspended page task. One
  /// projection, layout and anchor restoration owns the entire visible change.
  private func commitLoadedBatch(anchor: VisibleMessageAnchor?) -> Bool {
    let rowUpdate = chatRows.syncFromViewModelAfterManualMutation()
    guard rowUpdate != .none else { return false }
    isCommittingGeometry = true
    defer { isCommittingGeometry = false }
    pruneMessageSelection()
    clearHoveredMessage()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      switch rowUpdate {
        case let .insert(inserted):
          tableView.insertRows(at: inserted, withAnimation: .none)
          reloadGroupBoundaryRows(groupBoundaryRefreshRows(aroundInsertedRows: inserted))
        case .none:
          break
        default:
          tableView.reloadData()
      }
      tableView.layoutSubtreeIfNeeded()
      if let anchor { restoreVisibleMessageAnchor(anchor) }
    }
    scheduleAvatarOverlaySync()
    scheduleMediaWarmupForVisibleAndNearby(reason: "local_batch")
    scheduleMessageHoverRefresh()
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
    guard !isDisposed else { return }
    guard didFinalizeInitialMeasurementWidth else {
      _ = chatRows.apply(update)
      return
    }
    let followsLatest = isAtAbsoluteBottom && !isUserScrolling && !needsInitialScroll
    let anchor = captureVisibleMessageAnchor()
    isPerformingUpdate = true
    isCommittingGeometry = true
    defer {
      isCommittingGeometry = false
      isPerformingUpdate = false
      requestVisibleHistoryGap()
      scheduleAvatarOverlaySync()
      scheduleMediaWarmupForVisibleAndNearby(reason: "update")
      scheduleMessageHoverRefresh()
    }

    let rowUpdate = chatRows.apply(update)
    pruneMessageSelection()
    guard rowUpdate != .none else { return }
    clearHoveredMessage()

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = 0
    switch rowUpdate {
      case let .insert(inserted):
        tableView.insertRows(at: inserted, withAnimation: .none)
        reloadGroupBoundaryRows(groupBoundaryRefreshRows(aroundInsertedRows: inserted))
      case let .remove(removed):
        tableView.removeRows(at: removed, withAnimation: .none)
        // Removing a message can change grouping on either side of the old row.
        tableView.reloadData()
      case let .reloadRows(rows):
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        tableView.noteHeightOfRows(withIndexesChanged: rows)
      case .reloadAll:
        tableView.reloadData()
      case .none:
        break
    }
    tableView.layoutSubtreeIfNeeded()
    if !followsLatest, let anchor {
      restoreVisibleMessageAnchor(anchor)
    }
    NSAnimationContext.endGrouping()
    CATransaction.commit()
    if followsLatest {
      // Start movement outside the zero-duration geometry transaction. Subsequent
      // sends retarget from the current displayed offset instead of snapping.
      scrollToBottom(animated: true)
    }
    if case let .added(messages, _) = update { handleIncomingMessages(messages) }
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
    chatRows.measurement(for: message, props: props, width: tableWidth) {
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
      if Task.isCancelled { return }
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

    // Temporary read-on-open workaround: do not wait for history coverage or
    // an advancing incoming marker. readAll clears locally before sending.
    UnreadManager.shared.readAll(peerId, chatId: chatId)
    if isAtBottom { markMessagesSeen() }
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

  private func latestMessageId() -> Int64? {
    let latest = chatRows.reversed ? messages.first : messages.last
    return latest?.message.messageId
  }

  private func markMessagesSeen() {
    guard let latestId = latestMessageId() else {
      hasUnreadSinceScroll = false
      updateUnreadBadgeVisibility()
      return
    }
    lastSeenMessageId = latestId
    hasUnreadSinceScroll = false
    updateUnreadBadgeVisibility()
  }

  private func handleIncomingMessages(_ newMessages: [FullMessage]) {
    guard !newMessages.isEmpty else { return }
    if isAtBottom, chatRows.historyCoverage.isAtCertifiedLiveEnd {
      markMessagesSeen()
      return
    }

    let newestId = newMessages.map(\.message.messageId).max() ?? lastSeenMessageId
    if newestId > lastSeenMessageId {
      hasUnreadSinceScroll = true
      updateUnreadBadgeVisibility()
    }
  }

  private func updateUnreadBadgeVisibility() {
    scrollToBottomButton.setHasUnread(!isAtBottom && hasUnreadSinceScroll)
  }
}

extension ExperimentalMessageListAppKit: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    didFinalizeInitialMeasurementWidth ? chatRows.rowCount : 0
  }
}

extension ExperimentalMessageListAppKit: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    let allowed = chatRows.canSelect(row: row)
    MessageGestureTrace.trace("MessageList.shouldSelectRow row=\(row) allow=\(allowed)")
    return allowed
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
    !needsInitialScroll && !isCommittingGeometry
  }

  /// ceil'ed table width.
  /// ceiling prevent subpixel differences in height calc passes which can cause jitter
  private func tableWidth() -> CGFloat {
    measurementWidth() ?? rawMeasurementWidth(using: tableView)
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard !needsInitialScroll, let item = rowItem(at: row) else { return nil }

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

      case .historyHole:
        let cell = (tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("historyGap"), owner: self)
          as? MessageHistoryGapView) ?? MessageHistoryGapView(frame: .zero)
        cell.identifier = NSUserInterfaceItemIdentifier("historyGap")
        cell.setLoading(item == loadingHistoryGap)
        cell.onLoad = { [weak self] in self?.requestHistoryGap(item) }
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

      case .historyHole:
        return MessageHistoryGapView.height

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

extension ExperimentalMessageListAppKit {
  // MARK: - Scroll to message

  func scrollToMsgAndHighlight(_ request: ScrollToMessageRequest) {
    targetScrollRevision &+= 1
    let revision = targetScrollRevision
    scrollView.cancelAnimatedScroll()
    isProgrammaticScroll = false
    targetScrollTask?.cancel()
    targetScrollTask = nil
    discreteScrollEndTask?.cancel()
    discreteScrollEndTask = nil
    isUserScrolling = false
    guard request.messageId > 0, !isDisposed else { return }
    cancelPendingPages()
    if messages.contains(where: { $0.message.messageId == request.messageId }) {
      chatRows.setHistoryAnchor(request.messageId)
      scrollToMessage(request.messageId, shouldHighlight: true)
      return
    }
    let peer = peerId
    let limit = MessagesProgressiveViewModel.defaultInitialLimit()
    let previousMessageID = captureVisibleMessageAnchor()?.messageID ?? highestPositiveMessageId ?? request.messageId
    targetScrollTask = Task { @MainActor [weak self] in
      var loadingToast: UUID?
      defer {
        if let loadingToast { ToastCenter.shared.dismiss(loading: loadingToast) }
        if let self, revision == self.targetScrollRevision {
          self.targetScrollTask = nil
          self.requestVisibleHistoryGap()
        }
      }
      do {
        guard let self else { return }
        var hasWindow = try await chatRows.loadLocalWindowAroundMessageAsync(messageId: request.messageId)
        guard !Task.isCancelled, !isDisposed, revision == targetScrollRevision else { return }
        if !hasWindow {
          loadingToast = ToastCenter.shared.showLoading("Loading message…")
          let outcome = try await MessageHistoryRepairCoordinator.shared.loadAround(
            peer: peer, anchorID: request.messageId, limit: limit
          )
          guard !Task.isCancelled, !isDisposed, revision == targetScrollRevision else { return }
          guard outcome != .empty else {
            ToastCenter.shared.showError("Could not load that message")
            return
          }
          hasWindow = try await chatRows.loadLocalWindowAroundMessageAsync(messageId: request.messageId)
        }
        guard !Task.isCancelled, !isDisposed, revision == targetScrollRevision else { return }
        guard hasWindow else {
          ToastCenter.shared.showError("Could not load that message")
          return
        }
        scrollView.captureOutgoingViewport(direction: request.messageId < previousMessageID ? -1 : 1)
        isCommittingGeometry = true
        rebuildRowItems()
        clearHoveredMessage()
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        pruneMessageSelection()
        if let displayedMessageID = nearestDisplayedMessageID(to: request.messageId) {
          scrollToMessage(displayedMessageID, shouldHighlight: displayedMessageID == request.messageId, animated: true)
          if displayedMessageID != request.messageId {
            ToastCenter.shared.showInfo("Message unavailable. Showing nearby history.")
          }
        } else {
          ToastCenter.shared.showError("Could not load that message")
        }
        isCommittingGeometry = false
        scheduleAvatarOverlaySync()
        scheduleMessageHoverRefresh()
        persistReadingPosition()
      } catch is CancellationError {
        return
      } catch {
        guard let self, !Task.isCancelled, !isDisposed, revision == targetScrollRevision else { return }
        ToastCenter.shared.showError("Could not load that message")
      }
    }
  }

  private func nearestDisplayedMessageID(to coordinate: Int64) -> Int64? {
    let messageIDs = messages.lazy.map(\.message.messageId).filter { $0 > 0 }
    if messageIDs.contains(coordinate) { return coordinate }
    let neighbor = messageIDs.filter { $0 > coordinate }.min()
      ?? messageIDs.filter { $0 < coordinate }.max()
    return neighbor
      .flatMap { chatRows.historyCoverage.isCertifiedContinuation(between: coordinate, and: $0) ? $0 : nil }
  }

  private func scrollToMessage(_ msgId: Int64, shouldHighlight: Bool, animated: Bool = true) {
    guard let message = messages.first(where: { $0.message.messageId == msgId }),
          let row = chatRows.rowIndex(forMessageStableId: message.id) else { return }
    isAtBottom = false
    isAtAbsoluteBottom = false
    scrollToIndex(row, position: .center, animated: animated) { [weak self] in
      guard let self, shouldHighlight,
            let currentRow = chatRows.rowIndex(forMessageStableId: message.id) else { return }
      highlightMessage(at: currentRow)
    }
  }

  private func highlightMessage(at row: Int) {
    // Verify row is still valid (tableView state may have changed during animation)
    guard row >= 0, row < tableView.numberOfRows else {
      log.trace("Cannot highlight message at row \(row) - tableView has \(tableView.numberOfRows) rows")
      return
    }

    guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCell else {
      return
    }
    cell.highlight()
  }
}

extension ExperimentalMessageListAppKit {
  /// Applies one target movement after the final row geometry is available.
  /// - Parameters:
  ///   - index: The row index to scroll to
  ///   - position: Where in the viewport to position the row (default: center)
  ///   - animated: Whether to animate the scroll
  func scrollToIndex(
    _ index: Int, position: ScrollPosition = .center, animated: Bool = true,
    completion: (@MainActor () -> Void)? = nil
  ) {
    guard index >= 0, index < tableView.numberOfRows else { return }
    let rect = tableView.rect(ofRow: index)
    let viewport = scrollView.contentView.bounds
    let target: CGFloat = switch position {
      case .top: rect.minY - scrollView.contentInsets.top
      case .center: rect.midY - viewport.height / 2
      case .bottom: rect.maxY + scrollView.contentInsets.bottom - viewport.height
    }
    let clamped = clampScrollOffset(target)
    beginProgrammaticScroll()
    scrollView.moveViewport(to: clamped, animated: animated) { [weak self] in
      guard let self, !isDisposed else { return }
      endProgrammaticScroll()
      completion?()
    }
  }

  enum ScrollPosition {
    case top
    case center
    case bottom
  }
}

extension ExperimentalMessageListAppKit {
  func dispose() {
    guard !isDisposed else { return }
    persistReadingPosition()
    isDisposed = true
    scrollView.cancelAnimatedScroll()
    discreteScrollEndTask?.cancel()
    discreteScrollEndTask = nil
    cancellables.removeAll()

    // Cancel any tasks
    eventMonitorTask?.cancel()
    eventMonitorTask = nil
    integrationCheckTask?.cancel()
    integrationCheckTask = nil
    remoteOlderTask?.cancel()
    remoteOlderTask = nil
    remoteNewerTask?.cancel()
    remoteNewerTask = nil
    historyGapTask?.cancel()
    historyGapTask = nil
    targetScrollTask?.cancel()
    targetScrollTask = nil
    loadBatchTask?.cancel()
    loadBatchTask = nil
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
    onMessageSelectionChange = nil

    // Dispose view model
    chatRows.dispose()

    // Clear table view delegates
    tableView.delegate = nil
    tableView.dataSource = nil

    // Remove from parent if still attached
    view.removeFromSuperview()
    removeFromParent()

    log.trace("ExperimentalMessageListAppKit disposed: \(self)")
  }
}

private extension MessagesProgressiveViewModel.MessagesChangeSet {
  var experimentalTraceLabel: String {
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
