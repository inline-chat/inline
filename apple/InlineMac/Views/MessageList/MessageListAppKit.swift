import AppKit
import Combine
import InlineKit
import Logger
import SwiftUI
import Throttler
import Translation

class MessageListAppKit: NSViewController {
  // Data
  private var dependencies: AppDependencies
  private var peerId: Peer
  private var chat: Chat?
  private var chatId: Int64 { chat?.id ?? 0 }
  var viewModel: MessagesProgressiveViewModel
  private var messages: [FullMessage] { viewModel.messages }
  private var state: ChatState

  // MARK: - Interleaved rows (messages + day separators)

  private enum RowItem: Equatable, Hashable {
    case daySeparator(dayStart: Date)
    case message(id: Int64) // FullMessage.id (stable list identity)
  }

  private var rowItems: [RowItem] = []
  private var messageIndexById: [Int64: Int] = [:]
  private var rowIndexByMessageId: [Int64: Int] = [:]
  private var dayStartsInRowItems: Set<Date> = []

  private let log = Log.scoped("MessageListAppKit", enableTracing: false)
  private let sizeCalculator = MessageSizeCalculator.shared
  private let defaultRowHeight = 45.0

  // Specification - mostly useful in debug
  private var feature_scrollsToBottomOnNewMessage = true
  private var feature_setupsInsetsManually = true
  private var feature_updatesHeightsOnWidthChange = true
  private var feature_recalculatesHeightsWhileInitialScroll = true
  private var feature_loadsMoreWhenApproachingTop = true

  // Testing
  private var feature_updatesHeightsOnLiveResizeEnd = true
  private var feature_scrollsToBottomInDidLayout = true
  private var feature_maintainsScrollFromBottomOnResize = true

  // Not needed
  private var feature_updatesHeightsOnOffsetChange = false

  // Debugging
  private var debug_slowAnimation = false

  private var suppressResizeScrollMaintenance = false

  private var eventMonitorTask: Task<Void, Never>?
  private var cancellables: Set<AnyCancellable> = []

  // Translation system
  private let translationViewModel: TranslationViewModel
  private var hasAnalyzedInitialMessages = false
  private var deferredTranslationTask: Task<Void, Never>?
  private var hasDeferredInitialTranslation = false
  private var needsUnreadUpdateOnActive = false
  private var appActivityObserverId: UUID?

  init(dependencies: AppDependencies, peerId: Peer, chat: Chat) {
    self.dependencies = dependencies
    self.peerId = peerId
    self.chat = chat
    viewModel = MessagesProgressiveViewModel(peer: peerId)
    state = ChatsManager
      .get(
        for: peerId,
        chatId: chat.id
      )
    translationViewModel = TranslationViewModel(peerId: peerId)

    super.init(nibName: nil, bundle: nil)

    appActivityObserverId = AppActivityMonitor.shared.addObserver { [weak self] state in
      guard let self else { return }
      guard state == .active else { return }
      guard needsUnreadUpdateOnActive else { return }
      needsUnreadUpdateOnActive = false
      updateUnreadIfNeeded()
    }

    sizeCalculator.prepareForUse()
    rebuildRowItems()

    // observe data
    viewModel.observe { [weak self] update in
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
          case let .scrollToMsg(msgId):
            // scroll and highlight
            self_.scrollToMsgAndHighlight(msgId)

          case .scrollToBottom:
            if !self_.isAtBottom {
              self_.scrollToIndex(self_.tableView.numberOfRows - 1, position: .bottom, animated: true)
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
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private lazy var toolbarBgView: NSVisualEffectView = ChatToolbarView(dependencies: dependencies)
  private var pinnedHeaderHeight: CGFloat = 0
  private var pinnedHeaderTopConstraint: NSLayoutConstraint?
  private var pinnedHeaderHeightConstraint: NSLayoutConstraint?
  private lazy var pinnedHeaderView: PinnedMessageHeaderView = {
    let view = PinnedMessageHeaderView(dependencies: dependencies, peerId: peerId, chatId: chatId)
    view.onHeightChange = { [weak self] height in
      guard let self else { return }
      pinnedHeaderHeight = height
      pinnedHeaderHeightConstraint?.constant = height
      updateScrollViewInsets()
    }
    return view
  }()

  private func rebuildRowItems() {
    messageIndexById.removeAll(keepingCapacity: true)
    rowIndexByMessageId.removeAll(keepingCapacity: true)
    dayStartsInRowItems.removeAll(keepingCapacity: true)

    guard !messages.isEmpty else {
      rowItems = []
      return
    }

    let calendar = Calendar.autoupdatingCurrent
    var newRowItems: [RowItem] = []
    newRowItems.reserveCapacity(messages.count + 8)

    var previousDayStart: Date?

    for (index, message) in messages.enumerated() {
      messageIndexById[message.id] = index

      let dayStart = calendar.startOfDay(for: message.message.date)
      if previousDayStart == nil || dayStart != previousDayStart {
        newRowItems.append(.daySeparator(dayStart: dayStart))
        dayStartsInRowItems.insert(dayStart)
        previousDayStart = dayStart
      }

      newRowItems.append(.message(id: message.id))
    }

    rowItems = newRowItems

    for (row, item) in rowItems.enumerated() {
      if case let .message(id) = item {
        rowIndexByMessageId[id] = row
      }
    }
  }

  private func rowItem(at row: Int) -> RowItem? {
    guard row >= 0, row < rowItems.count else { return nil }
    return rowItems[row]
  }

  private func messageStableId(forRow row: Int) -> Int64? {
    guard let item = rowItem(at: row) else { return nil }
    if case let .message(id) = item { return id }
    return nil
  }

  private func toggleToolbarVisibility(_ hide: Bool) {
    if #available(macOS 26.0, *) {
      // No toolbar on macOS 14
    } else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.08
        context.allowsImplicitAnimation = true

        toolbarBgView.alphaValue = hide ? 0 : 1
      }
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

  private lazy var scrollView: NSScrollView = {
    let scroll = MessageListScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    scroll.backgroundColor = .clear
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = tableView
    scroll.hasVerticalScroller = true
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

  private var scrollToBottomBottomConstraint: NSLayoutConstraint!
  private lazy var scrollToBottomButton: ScrollToBottomButtonHostingView = {
    let scrollToBottomButton = ScrollToBottomButtonHostingView()
    scrollToBottomButton.onClick = { [weak self] in
      guard let weakSelf = self else { return }
      // self?.scrollToBottom(animated: true)
      weakSelf.scrollToIndex(weakSelf.tableView.numberOfRows - 1, position: .bottom, animated: true)
      weakSelf.scrollToBottomButton.setVisibility(false)
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
    hideScrollbars() // until initial scroll is done

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      self?.enableScrollbars()
    }

    log.trace("viewDidLoad for chat \(chatId)")

    Task { [weak self] in
      guard let self, let chat else { return }
      await NotionTaskService.shared.checkIntegrationAccess(peerId: peerId, spaceId: chat.spaceId)
    }
  }

  // MARK: - Insets

  private var insetForCompose: CGFloat = Theme.composeMinHeight
  func updateInsetForCompose(_ inset: CGFloat, animate: Bool = true) {
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

    if isAtBottom {
      tableView.scrollToBottomWithInset(cancel: false)
    }
  }

  private func setInsets() {
    // TODO: extract insets logic from bottom here.
  }

  private var toolbarHeight: CGFloat = AppSettings.shared.enableNewMacUI ? Theme.toolbarHeight : 52

  // This fixes the issue with the toolbar messing up initial content insets on window open. Now we call it on did
  // layout and it fixes the issue.
  private func updateScrollViewInsets() {
    guard feature_setupsInsetsManually else { return }
    guard let window = view.window else { return }

    let windowFrame = window.frame
    let contentFrame = window.contentLayoutRect
    let toolbarHeight = windowFrame.height - contentFrame.height
    self.toolbarHeight = toolbarHeight
    let topInset = toolbarHeight + pinnedHeaderHeight

    pinnedHeaderTopConstraint?.constant = toolbarHeight
    pinnedHeaderHeightConstraint?.constant = pinnedHeaderHeight

    if scrollView.contentInsets.top != topInset {
      log.trace("Adjusting view's insets")

      let wasAtBottom = isAtBottom
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

      if !needsInitialScroll {
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

  private func clampScrollOffset(_ offset: CGFloat) -> CGFloat {
    let contentHeight = scrollView.documentView?.bounds.height ?? 0
    let viewportHeight = scrollView.contentView.bounds.height
    let maxOffset = max(0, contentHeight - viewportHeight)
    return min(max(offset, 0), maxOffset)
  }

  private func isAtTop() -> Bool {
    let scrollOffset = scrollView.contentView.bounds.origin
    return scrollOffset.y <= min(-scrollView.contentInsets.top, 0)
  }

  private func userVisibleRect() -> NSRect {
    tableView.visibleRect.insetBy(
      dx: 0,
      dy: -scrollView.contentInsets.bottom - scrollView.contentInsets.top
    )
  }

  private func updateMessageViewColors() {}

  private var isToolbarVisible = false

  private func updateToolbar() {
    // make window toolbar layout and have background to fight the swiftui defaUlt behaviour
    log.trace("Adjusting view's toolbar")

    if #available(macOS 26.0, *) {
      isToolbarVisible = false
    } else {
      let atTop = isAtTop()
      isToolbarVisible = !atTop
      toggleToolbarVisibility(atTop)
    }
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

    if #available(macOS 26.0, *) {
      // No BG
    } else {
      view.addSubview(toolbarBgView)

      NSLayoutConstraint.activate([
        toolbarBgView.topAnchor.constraint(equalTo: view.topAnchor),
        toolbarBgView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        toolbarBgView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        toolbarBgView.heightAnchor.constraint(equalToConstant: toolbarHeight),
      ])
    }

    view.addSubview(pinnedHeaderView)
    pinnedHeaderTopConstraint = pinnedHeaderView.topAnchor.constraint(equalTo: view.topAnchor, constant: toolbarHeight)
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
        constant: -12
      ),
      scrollToBottomBottomConstraint,
      scrollToBottomButton.widthAnchor.constraint(equalToConstant: Theme.scrollButtonSize),
      scrollToBottomButton.heightAnchor.constraint(equalToConstant: Theme.scrollButtonSize),
    ])
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

  private func scrollToBottom(animated: Bool) {
    guard !rowItems.isEmpty else { return }
    #if DEBUG
    log.trace("Scrolling to bottom animated=\(animated)")
    #endif

    isProgrammaticScroll = true

    defer {
      isProgrammaticScroll = false
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

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(liveResizeEnded),
      name: NSWindow.didEndLiveResizeNotification,
      object: scrollView.window
    )
  }

  private var scrollState: MessageListScrollState = .idle {
    didSet {
      NotificationCenter.default.post(
        name: .messageListScrollStateDidChange,
        object: self,
        userInfo: ["state": scrollState]
      )
    }
  }

  @objc private func scrollWheelBegan() {
    log.trace("scroll wheel began")
    isUserScrolling = true
    scrollState = .scrolling
  }

  @objc private func scrollWheelEnded() {
    log.trace("scroll wheel ended")
    isUserScrolling = false
    scrollState = .idle

    DispatchQueue.main.async(qos: .userInitiated) { [weak self] in
      self?.updateUnreadIfNeeded()
    }
  }

  // Recalculate heights for all items once resize has ended
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
  private func fullWidthAsyncCalc(maintainScroll: Bool = true) {
    precalculateHeightsInBackground()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      // Recalculate all height when user is done resizing
      self?.recalculateHeightsOnWidthChange(buffer: 400, maintainScroll: maintainScroll)
    }
  }

  // True while we're changing scroll position programmatically
  private var isProgrammaticScroll = false

  // True when user is scrolling via trackpad or mouse wheel
  private var isUserScrolling = false

  // True when user is at the bottom of the scroll view within a ~0-10px threshold
  private var isAtBottom = true {
    didSet {
      viewModel.setAtBottom(isAtBottom)
    }
  }

  // When exactly at the bottom
  private var isAtAbsoluteBottom = true
  private var lastSeenMessageId: Int64 = 0
  private var hasUnreadSinceScroll = false

  // This must be true for the whole duration of animation
  private var isPerformingUpdate = false

  private var prevContentSize: CGSize = .zero
  private var prevOffset: CGFloat = 0

  @objc func scrollViewBoundsChanged(notification: Notification) {
    throttle(.milliseconds(32), identifier: "chat.scrollViewBoundsChanged", by: .mainActor, option: .default) { [
      weak self
    ] in
      self?.handleBoundsChange()
    }
  }

  func updateToolbarDebounced() {
    if isToolbarVisible {
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

  private func handleBoundsChange() {
    let scrollOffset = scrollView.contentView.bounds.origin
    let viewportSize = scrollView.contentView.bounds.size
    let contentSize = scrollView.documentView?.frame.size ?? .zero
    let maxScrollableHeight = contentSize.height - viewportSize.height
    let currentScrollOffset = scrollOffset.y

    // Update stores values
    oldDistanceFromBottom = contentSize.height - scrollOffset.y - viewportSize.height

    if needsInitialScroll {
      // reports inaccurate heights at this point
      return
    }

    // Prevent iaAtBottom false negative when elastic scrolling
    let overScrolledToBottom = currentScrollOffset > maxScrollableHeight
    let prevAtBottom = isAtBottom
    isAtBottom = overScrolledToBottom || abs(currentScrollOffset - maxScrollableHeight) <= 5.0
    isAtAbsoluteBottom = overScrolledToBottom || abs(currentScrollOffset - maxScrollableHeight) <= 0.1

    // Check if we're approaching the top
    if feature_loadsMoreWhenApproachingTop, isUserScrolling, currentScrollOffset < viewportSize.height {
      loadBatch(at: .older)
    }

    updateToolbarDebounced()

    if prevAtBottom != isAtBottom {
      let shouldShow = !isAtBottom // && messages.count > 0
      scrollToBottomButton.setVisibility(shouldShow)
      if isAtBottom {
        markMessagesSeen()
      } else {
        updateUnreadBadgeVisibility()
      }
    }
  }

  // Using CFAbsoluteTimeGetCurrent()
  private func measureTime(_ closure: () -> Void, name: String = "Function") {
    let start = CFAbsoluteTimeGetCurrent()
    closure()
    let end = CFAbsoluteTimeGetCurrent()
    let timeElapsed = (end - start) * 1_000 // Convert to milliseconds
    log.trace("\(name) took \(String(format: "%.2f", timeElapsed))ms")
  }

  var oldScrollViewHeight: CGFloat = 0.0
  var oldDistanceFromBottom: CGFloat = 0.0
  var previousViewportHeight: CGFloat = 0.0

  @objc func scrollViewFrameChanged(notification: Notification) {
    updateMessageViewColors()

    if suppressResizeScrollMaintenance {
      return
    }

    // keep scroll view anchored from the bottom
    guard feature_maintainsScrollFromBottomOnResize else { return }

    // Already handled in this case
    if feature_scrollsToBottomInDidLayout, isAtAbsoluteBottom {
      return
    }

    if needsInitialScroll {
      return
    }

    guard let documentView = scrollView.documentView else { return }

    if isPerformingUpdate {
      // Do not maintain scroll when performing update, TODO: Fix later
      return
    }

    #if DEBUG
    log.trace("scroll view frame changed, maintaining scroll from bottom")
    #endif

    let viewportSize = scrollView.contentView.bounds.size

    // DISABLED CHECK BECAUSE WIDTH CAN CHANGE THE MESSAGES
    // Only do this if frame height changed. Width is handled in another function
//    if abs(viewportSize.height - previousViewportHeight) < 0.1 {
//      return
//    }

    let scrollOffset = scrollView.contentView.bounds.origin
    let contentSize = scrollView.documentView?.frame.size ?? .zero

    #if DEBUG
    log
      .trace(
        "scroll view frame changed, maintaining scroll from bottom \(contentSize.height) \(previousViewportHeight)"
      )
    #endif
    previousViewportHeight = viewportSize.height

    // TODO: min max
    let nextScrollPosition = contentSize.height - (oldDistanceFromBottom + viewportSize.height)

    if nextScrollPosition == scrollOffset.y {
      #if DEBUG
      log.trace("scroll position is same, skipping maintaining")
      #endif
      return
    }

    // Early return if no change needed
    if abs(nextScrollPosition - scrollOffset.y) < 0.5 { return }

    scrollView.contentView.updateBounds(NSPoint(x: 0, y: nextScrollPosition), cancel: true)

    // CATransaction.begin()
    // CATransaction.setDisableActions(true)
    // Set new scroll position
    // documentView.scroll(NSPoint(x: 0, y: nextScrollPosition))
    // scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: nextScrollPosition))
    // CATransaction.commit()

    //    Looked a bit laggy to me
//    NSAnimationContext.runAnimationGroup { context in
//      context.duration = 0
//      context.allowsImplicitAnimation = false
//      documentView.scroll(NSPoint(x: 0, y: nextScrollPosition))
//    }
  }

  private var lastKnownWidth: CGFloat = 0
  private var needsInitialScroll = true

  private func hideScrollbars() {
    scrollView.hasVerticalScroller = false
    scrollView.verticalScroller?.isHidden = true
    scrollView.verticalScroller?.alphaValue = 0.0
  }

  private func enableScrollbars() {
    scrollView.hasVerticalScroller = true
    scrollView.verticalScroller?.isHidden = false
    scrollView.verticalScroller?.alphaValue = 1.0
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    #if DEBUG
    log.trace("viewDidLayout() called, width=\(tableWidth())")
    #endif

    updateToolbar()

    updateColumnWidthAndCommit()

    updateScrollViewInsets()

    checkWidthChangeForHeights()

    // Initial scroll to bottom
    if needsInitialScroll {
      if feature_recalculatesHeightsWhileInitialScroll {
        // Note(@mo): I still don't know why this fixes it but as soon as I compare the widths for the change,
        // it no longer works. this needs to be called unconditionally.
        // this is needed to ensure the scroll is done after the initial layout and prevents cutting off last msg
        // EXPERIMENTAL: GETTING RID OF THIS FOR PERFORMANCE REASONS
        // let _ = recalculateHeightsOnWidthChange(maintainScroll: false)

        // fullWidthAsyncCalc(maintainScroll: true)
      }

      scrollToBottom(animated: false)
      markMessagesSeen()

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self else { return }
        // Finalize heights one last time to ensure no broken heights on initial load
        needsInitialScroll = false
      }
    }

    if feature_scrollsToBottomInDidLayout {
      // Note(@mo): This is a hack to fix scroll jumping when user is resizing the window at bottom.
      if isAtAbsoluteBottom, !isPerformingUpdate, !needsInitialScroll {
        // TODO: see how we can avoid this when user is sending message and we're resizing it's fucked up
        scrollToBottom(animated: false)
      }
    }
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    log.trace("viewWillAppear() called")
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    log.trace("viewDidAppear() called")
    updateScrollViewInsets()
    updateToolbar()
  }

  override func viewWillDisappear() {
    super.viewWillDisappear()
    log.trace("viewWillDisappear() called")
  }

  override func viewDidDisappear() {
    super.viewDidDisappear()
    log.trace("viewDidDisappear() called")
  }

  override func viewWillLayout() {
    super.viewWillLayout()
    log.trace("viewWillLayout() called")
  }

  private var wasLastResizeAboveLimit = false

  // Called on did layout
  func checkWidthChangeForHeights() {
    guard feature_updatesHeightsOnWidthChange else { return }

    #if DEBUG
    log.trace("Checking width change, diff = \(abs(tableView.bounds.width - lastKnownWidth))")
    #endif
    let newWidth = tableView.bounds.width

    // Using this prevents an issue where cells height was stuck in a cut off way when using
    // MessageSizeCalculator.safeAreaWidth as the diff
    // let magicWidthDiff = 15.0

    // Experimental
    // let magicWidthDiff = 1.0
    let magicWidthDiff = 0.5

    if abs(newWidth - lastKnownWidth) > magicWidthDiff {
      let wasPrevWidthZero = lastKnownWidth == 0
      lastKnownWidth = newWidth

      /// Below used to check if width is above max width to not calculate anything, but
      /// this results in very subtle bugs, eg. when window was smaller, then increased width beyond max (so the
      /// calculations are paused, then increases height. now the recalc doesn't happen for older messages.

      if needsInitialScroll, !wasPrevWidthZero {
        recalculateHeightsOnWidthChange(duringLiveResize: false, maintainScroll: false)
        return
      }

      // TODO: Calculate buffer based on screen height to get smooth maximize

      recalculateHeightsOnWidthChange(
        buffer: 3,
        duringLiveResize: true,
        maintainScroll: !isAtBottom
        // maintainScroll: false
      )

      // COMMENTED FOR NOW TO SEE IF IT WAS OWRTH THE EXTRA BUGS THAT
      // APPEAR during live resize while maximize

//
//      let availableWidth = sizeCalculator.getAvailableWidth(
//        tableWidth: tableWidth()
//      )
//      if availableWidth < Theme.messageMaxWidth {
//        recalculateHeightsOnWidthChange(duringLiveResize: true)
//        wasLastResizeAboveLimit = false
//      } else {
//        if !wasLastResizeAboveLimit {
//          // One last time just before stopping at the limit. This is import so stuff don't get stuck
//          recalculateHeightsOnWidthChange(duringLiveResize: true)
//          wasLastResizeAboveLimit = true
//        } else {
//          log.trace("skipped width recalc")
//        }
//      }
    }
  }

  private var loadingBatch = false

  // Currently only at top is supported.
  func loadBatch(at direction: MessagesProgressiveViewModel.MessagesLoadDirection) {
    if direction != .older { return }
    if loadingBatch { return }
    loadingBatch = true

    Task { [weak self] in
      guard let self else { return }
      // Preserve scroll position from bottom if we're loading at top
      maintainingBottomScroll { [weak self] in
        guard let self else { return false }

        log.trace("Loading batch at top")
        let oldRowItems = rowItems
        let oldRowCount = oldRowItems.count
        viewModel.loadBatch(at: direction, publish: false)
        rebuildRowItems()
        let newRowCount = rowItems.count
        let diff = newRowCount - oldRowCount

        if diff > 0 {
          // Only apply incremental inserts when it's provably a pure prefix insert.
          if rowItems.suffix(oldRowCount).elementsEqual(oldRowItems) {
            let newIndexes = IndexSet(0 ..< diff)
            tableView.beginUpdates()
            tableView.insertRows(at: newIndexes, withAnimation: .none)
            tableView.endUpdates()
          } else if
            oldRowCount > 1,
            newRowCount > 1,
            rowItems.first == oldRowItems.first,
            rowItems.suffix(oldRowCount - 1).elementsEqual(oldRowItems.dropFirst())
          {
            // Common case: loading older messages that are on the same day as the first visible message.
            // The first day separator stays in place, and new message rows are inserted right after it.
            let newIndexes = IndexSet(integersIn: 1 ..< (1 + diff))
            tableView.beginUpdates()
            tableView.insertRows(at: newIndexes, withAnimation: .none)
            tableView.endUpdates()
          } else {
            tableView.reloadData()
          }

          loadingBatch = false
          return true
        }

        // Don't maintain
        loadingBatch = false
        return false
      }
    }
  }

  func applyInitialData() {
    rebuildRowItems()
    tableView.reloadData()
  }

  func applyUpdate(_ update: MessagesProgressiveViewModel.MessagesChangeSet) {
    isPerformingUpdate = true

    // using "atBottom" here might add jitter if user is scrolling slightly up and then we move it down quickly
    let wasAtBottom = isAtAbsoluteBottom
    let animationDuration = debug_slowAnimation ? 1.5 : 0.15
    let shouldScroll = wasAtBottom && feature_scrollsToBottomOnNewMessage &&
      !isUserScrolling // to prevent jitter when user is scrolling

    let oldRowItems = rowItems
    let oldRowCount = oldRowItems.count
    let oldRowIndexByMessageId = rowIndexByMessageId

    rebuildRowItems()
    let newRowItems = rowItems
    let newRowCount = newRowItems.count

    func reloadAll(animated: Bool) {
      if animated {
        NSAnimationContext.runAnimationGroup { [weak self] context in
          guard let self else { return }
          context.duration = animationDuration
          tableView.reloadData()
          if shouldScroll { scrollToBottom(animated: true) }
        } completionHandler: { [weak self] in
          self?.isPerformingUpdate = false
        }
      } else {
        tableView.reloadData()
        if shouldScroll { scrollToBottom(animated: false) }
        isPerformingUpdate = false
      }
    }

    func applyStructuralInsert(animated: Bool, inserted: IndexSet) {
      if animated {
        NSAnimationContext.runAnimationGroup { [weak self] context in
          guard let self else { return }
          context.duration = animationDuration
          tableView.insertRows(at: inserted, withAnimation: .effectFade)
          if shouldScroll { scrollToBottom(animated: true) }
        } completionHandler: { [weak self] in
          self?.isPerformingUpdate = false
        }
      } else {
        tableView.beginUpdates()
        tableView.insertRows(at: inserted, withAnimation: .none)
        tableView.endUpdates()
        if shouldScroll { scrollToBottom(animated: false) }
        isPerformingUpdate = false
      }
    }

    func applyStructuralRemove(animated: Bool, removed: IndexSet) {
      if animated {
        NSAnimationContext.runAnimationGroup { [weak self] context in
          guard let self else { return }
          context.duration = animationDuration
          tableView.removeRows(at: removed, withAnimation: .effectFade)
          if shouldScroll { scrollToBottom(animated: true) }
        } completionHandler: { [weak self] in
          self?.isPerformingUpdate = false
        }
      } else {
        tableView.beginUpdates()
        tableView.removeRows(at: removed, withAnimation: .none)
        tableView.endUpdates()
        if shouldScroll { scrollToBottom(animated: false) }
        isPerformingUpdate = false
      }
    }

    switch update {
      case let .added(newMessages, _):
        log.trace("applying add changes")

        // Do incremental inserts only for provably-correct prefix/suffix insertions.
        if newRowCount > oldRowCount, newRowItems.starts(with: oldRowItems) {
          let inserted = IndexSet(integersIn: oldRowCount ..< newRowCount)
          applyStructuralInsert(animated: true, inserted: inserted)
        } else if newRowCount > oldRowCount, newRowItems.suffix(oldRowCount).elementsEqual(oldRowItems) {
          let inserted = IndexSet(integersIn: 0 ..< (newRowCount - oldRowCount))
          applyStructuralInsert(animated: true, inserted: inserted)
        } else {
          reloadAll(animated: true)
        }
        handleIncomingMessages(newMessages)

      case let .deleted(deletedIds, _):
        if newRowCount < oldRowCount, oldRowItems.starts(with: newRowItems) {
          let removed = IndexSet(integersIn: newRowCount ..< oldRowCount)
          applyStructuralRemove(animated: true, removed: removed)
          break
        }

        if newRowCount < oldRowCount, oldRowItems.suffix(newRowCount).elementsEqual(newRowItems) {
          let removed = IndexSet(integersIn: 0 ..< (oldRowCount - newRowCount))
          applyStructuralRemove(animated: true, removed: removed)
          break
        }

        // Guarded delete animation for small mid-list deletes (correctness-first).
        if !deletedIds.isEmpty, deletedIds.count <= 3 {
          var removedIndexes = Set<Int>()
          var removedDayStarts = Set<Date>()

          for deletedId in deletedIds {
            guard let messageRow = oldRowIndexByMessageId[deletedId] else { continue }
            removedIndexes.insert(messageRow)

            // Find the closest separator above the message in the old model.
            var cursor = messageRow - 1
            while cursor >= 0 {
              if case let .daySeparator(dayStart) = oldRowItems[cursor] {
                removedDayStarts.insert(dayStart)
                break
              }
              cursor -= 1
            }
          }

          for dayStart in removedDayStarts {
            if !dayStartsInRowItems.contains(dayStart) {
              // Remove that separator too (if it existed in the old model).
              if let separatorIndex = oldRowItems.firstIndex(of: .daySeparator(dayStart: dayStart)) {
                removedIndexes.insert(separatorIndex)
              }
            }
          }

          var removed = IndexSet()
          for idx in removedIndexes {
            removed.insert(idx)
          }
          if removed.count == oldRowCount - newRowCount {
            var remaining: [RowItem] = []
            remaining.reserveCapacity(oldRowCount - removed.count)
            for (idx, item) in oldRowItems.enumerated() where !removed.contains(idx) {
              remaining.append(item)
            }

            if remaining == newRowItems {
              applyStructuralRemove(animated: true, removed: removed)
              break
            }
          }
        }

        reloadAll(animated: true)

      case let .updated(updatedMessages, indexSet, animated):
        _ = updatedMessages // silence unused warning

        // Only do row-level reloads when structure is unchanged.
        guard oldRowItems == newRowItems else {
          reloadAll(animated: animated == true)
          break
        }

        // Map message indices -> stable ids -> row indices.
        var rowsToReload = IndexSet()
        for messageIndex in indexSet {
          guard messages.indices.contains(messageIndex) else { continue }
          let stableId = messages[messageIndex].id
          if let row = rowIndexByMessageId[stableId] {
            rowsToReload.insert(row)
          }
        }

        if rowsToReload.isEmpty {
          isPerformingUpdate = false
          break
        }

        if animated == true {
          NSAnimationContext.runAnimationGroup { [weak self] context in
            guard let self else { return }
            context.duration = animationDuration
            tableView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet([0]))
            tableView.noteHeightOfRows(withIndexesChanged: rowsToReload)
            if shouldScroll { scrollToBottom(animated: true) } // ??
          } completionHandler: { [weak self] in
            self?.isPerformingUpdate = false
          }
        } else {
          tableView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet([0]))
          tableView.noteHeightOfRows(withIndexesChanged: rowsToReload)
          if shouldScroll { scrollToBottom(animated: true) }
          isPerformingUpdate = false
        }

      case .reload:
        log.trace("reloading data")
        reloadAll(animated: false)
    }
  }

  // TODO: probably can optimize this
  private func maintainingBottomScroll(_ closure: () -> Bool?) {
    // Capture current scroll position relative to bottom
    let viewportHeight = scrollView.contentView.bounds.height
    let currentOffset = scrollView.contentView.bounds.origin.y

    // Execute the closure that modifies the data
    if let shouldMaintain = closure(), !shouldMaintain {
      return
    }

    // scrollView.layoutSubtreeIfNeeded()

    // Calculate and set new scroll position
    let newContentHeight = scrollView.documentView?.frame.height ?? 0
    //    let newOffset = newContentHeight - (distanceFromBottom + viewportHeight)
    let newOffset = newContentHeight - (oldDistanceFromBottom + viewportHeight)

    #if DEBUG
    log.trace("Maintaining scroll from bottom, oldOffset=\(currentOffset), newOffset=\(newOffset)")
    #endif

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    scrollView.documentView?.scroll(NSPoint(x: 0, y: newOffset))
    CATransaction.commit()
  }

  enum ScrollAnchorPosition {
    case bottomRow
  }

  enum ScrollAnchor {
    case bottom(row: Int, distanceFromViewportBottom: CGFloat)
  }

  ///
  /// Notes:
  /// - this relies on item index so doesn't work if items are added/removed for now
  private func anchorScroll(to: ScrollAnchorPosition) -> (() -> Void) {
    // let visibleRect = scrollView.contentView.bounds
    let visibleRect = tableView.visibleRect

    let bottomInset = scrollView.contentInsets.bottom
    let visibleRectInsetted = NSRect(
      x: visibleRect.origin.x,
      y: visibleRect.origin.y,
      width: visibleRect.width,
      height: visibleRect.height - bottomInset
    )
    #if DEBUG
    log.trace("Anchoring to bottom. Visible rect: \(visibleRectInsetted) inset: \(bottomInset)")
    #endif

    let viewportHeight = scrollView.contentView.bounds.height
    let currentOffset = scrollView.contentView.bounds.origin.y
    let viewportMinYOffset: CGFloat = currentOffset + viewportHeight

    // Capture anchor snapshot
    var anchor: ScrollAnchor

    switch to {
      case .bottomRow:
        // last one fails to give correct rect...
        let index = min(tableView.rows(in: visibleRectInsetted).max - 1, tableView.numberOfRows - 2)

        let rowRect = tableView.rect(ofRow: index)

        // Calculate distance from row's TOP edge to viewport's bottom edge
        let topEdgeToViewportBottom = rowRect.minY - visibleRect.maxY

        anchor = .bottom(row: index, distanceFromViewportBottom: topEdgeToViewportBottom)
        #if DEBUG
//        log.trace("""
//                Anchoring to bottom row: \(index),
//                distance: \(topEdgeToViewportBottom)
//                row.minY=\(rowRect.minY)
//                row.maxY=\(rowRect.maxY)
//                row.height=\(rowRect.height)
//                visibleRect.minY=\(visibleRect.minY)
//                visibleRect.maxY=\(visibleRect.maxY)
//        """)
        #endif
    }

    return { [weak self] in
      guard let self else { return }

      // see if it's needed
      scrollView.layoutSubtreeIfNeeded()

      switch anchor {
        case let .bottom(row, distanceFromViewportBottom):
          // Get the updated rect for the anchor row
          let rowRect = tableView.rect(ofRow: row)

          // Calculate new scroll position to maintain the same distance from viewport bottom
          let viewportHeight = scrollView.contentView.bounds.height
          let targetY = rowRect.minY - viewportHeight - distanceFromViewportBottom

          // Apply new scroll position
          let newOrigin = CGPoint(x: 0, y: targetY)

          scrollView.contentView.updateBounds(newOrigin, cancel: true)
      }
    }
  }

  // Note this function will stop any animation that is happening so must be used with caution
  // increasing buffer results in unstable scroll if not maintained
  private func recalculateHeightsOnWidthChange(
    buffer: Int = 0,
    duringLiveResize: Bool = false,
    maintainScroll: Bool = true
  ) {
    #if DEBUG
    log.trace("Recalculating heights on width change")
    #endif

    // should we keep this??
    if isPerformingUpdate {
      log.trace("Ignoring recalculation due to ongoing update")
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

    #if DEBUG
    log.trace("Rows to update: \(rowsToUpdate)")
    #endif
    let apply: (() -> Void)? = if maintainScroll { anchorScroll(to: .bottomRow) } else { nil }
    CATransaction.begin()
    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = 0

    tableView.beginUpdates()
    // Update heights in cells and setNeedsDisplay
    updateHeightsForRows(at: rowsToUpdate)

    // Experimental: noteheight of rows was below reload data initially
    tableView.noteHeightOfRows(withIndexesChanged: rowsToUpdate)
    tableView.endUpdates()

    apply?()
    NSAnimationContext.endGrouping()
    CATransaction.commit()
  }

  private func updateHeightsForRows(at indexSet: IndexSet) {
    for row in indexSet {
      if let rowView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCell {
        let inputProps = messageProps(for: row)
        if let message = message(forRow: row) {
          let (_, _, _, plan) = sizeCalculator.calculateSize(
            for: message,
            with: inputProps,
            tableWidth: tableWidth()
          )

          let props = MessageViewProps(
            firstInGroup: inputProps.firstInGroup,
            isLastMessage: inputProps.isLastMessage,
            isFirstMessage: inputProps.isFirstMessage,
            isRtl: inputProps.isRtl,
            isDM: chat?.type == .privateChat,
            index: messageIndexById[message.id],
            translated: inputProps.translated,
            layout: plan,
          )

          rowView.updateSizeWithProps(props: props)
        }
      }
    }
  }

  enum RowGroup {
    case all
    case visible
  }

  /// precalculate heights for a width
  private func precalculateHeightsInBackground(rowGroup: RowGroup = .all, width: CGFloat? = nil) {
    log.trace("precalculateHeightsInBackground")
    let width_ = width ?? tableWidth()
    // for now
    let rowsToUpdate: IndexSet
    switch rowGroup {
      case .all:
        rowsToUpdate = IndexSet(integersIn: 0 ..< tableView.numberOfRows)
      case .visible:
        let visibleRange = tableView.rows(in: tableView.visibleRect)
        rowsToUpdate = IndexSet(integersIn: visibleRange.location ..< visibleRange.location + visibleRange.length)
    }

    Task(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      for row in rowsToUpdate {
        guard let message = message(forRow: row) else { continue }
        let props = messageProps(for: row)
        let _ = sizeCalculator.calculateSize(for: message, with: props, tableWidth: width_)
      }
    }
  }

  private func message(forRow row: Int) -> FullMessage? {
    guard let stableId = messageStableId(forRow: row) else { return nil }
    guard let messageIndex = messageIndexById[stableId], messages.indices.contains(messageIndex) else { return nil }
    return messages[messageIndex]
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
    guard let message = message(forRow: row) else {
      return MessageViewInputProps(
        firstInGroup: true,
        isLastMessage: true,
        isFirstMessage: true,
        isDM: chat?.type == .privateChat,
        isRtl: false,
        translated: false
      )
    }

    return MessageViewInputProps(
      firstInGroup: isFirstInGroup(at: row),
      isLastMessage: isLastMessage(at: row),
      isFirstMessage: isFirstMessage(at: row),
      isDM: chat?.type == .privateChat,
      isRtl: false,
      translated: message.isTranslated
    )
  }

  private func calculateNewHeight(forRow row: Int) -> CGFloat {
    guard let message = message(forRow: row) else {
      return defaultRowHeight
    }

    let props = messageProps(for: row)

    let (_, _, _, plan) = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth())
    return plan.totalHeight
  }

  deinit {
    dispose()

    Log.shared.debug("🗑️ Deinit: \(type(of: self)) - \(self)")
  }

  // MARK: - Translation

  private func handleTranslationForUpdate(_ update: MessagesProgressiveViewModel.MessagesChangeSet) {
    guard AppSettings.shared.translationUIEnabled else { return }
    switch update {
      case .reload:
        // Trigger translation on all current messages
        scheduleTranslationWork(messages: viewModel.messages, analyzeForDetection: true)

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
    guard !messages.isEmpty else { return }

    deferredTranslationTask?.cancel()
    deferredTranslationTask = Task(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      await self.performTranslationWork(messages: messages, analyzeForDetection: analyzeForDetection)
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

  func readAll() {
    Task {
      UnreadManager.shared.readAll(peerId, chatId: chatId)
    }
  }

  func updateUnreadIfNeeded() {
    guard AppActivityMonitor.shared.isActive else {
      needsUnreadUpdateOnActive = true
      return
    }

    // Quicker check
    if isAtBottom {
      readAll()
      markMessagesSeen()
      return
    }

    let visibleRect = tableView.visibleRect
    let visibleRange = tableView.rows(in: visibleRect)
    let maxRow = tableView.numberOfRows - 1
    let isLastRowVisible = visibleRange.location + visibleRange.length >= maxRow

    if isLastRowVisible {
      readAll()
      markMessagesSeen()
    }
  }

  private func latestMessageId() -> Int64? {
    let latest = viewModel.reversed ? messages.first : messages.last
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
    if isAtBottom {
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

final class DateSeparatorTableCell: NSView {
  static let height: CGFloat = 34

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
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
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

extension MessageListAppKit: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    rowItems.count
  }
}

extension MessageListAppKit: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
    messageStableId(forRow: row) != nil
  }

  func isFirstInGroup(at row: Int) -> Bool {
    guard let message = message(forRow: row) else { return true }
    guard let index = messageIndexById[message.id] else { return true }
    guard index > 0 else { return true }

    let current = messages[index]
    let previous = messages[index - 1]
    if previous.message.fromId != current.message.fromId {
      return true
    }

    // Day boundary should start a new group (even for the same sender).
    let calendar = Calendar.autoupdatingCurrent
    return calendar.startOfDay(for: previous.message.date) != calendar.startOfDay(for: current.message.date)
//    return previous.message.fromId != current.message.fromId ||
//      current.message.date.timeIntervalSince(previous.message.date) > 300
  }

  func isLastMessage(at row: Int) -> Bool {
    guard let message = message(forRow: row) else { return false }
    guard let index = messageIndexById[message.id] else { return false }
    return index == messages.count - 1
  }

  func isFirstMessage(at row: Int) -> Bool {
    guard let message = message(forRow: row) else { return false }
    guard let index = messageIndexById[message.id] else { return false }
    return index == 0
  }

  var animateUpdates: Bool {
    // don't animate initial layout
    !needsInitialScroll
  }

  /// ceil'ed table width.
  /// ceiling prevent subpixel differences in height calc passes which can cause jitter
  private func tableWidth() -> CGFloat {
    ceil(tableView.bounds.width)
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

      case let .message(id):
        guard let messageIndex = messageIndexById[id], messages.indices.contains(messageIndex) else { return nil }
        let message = messages[messageIndex]

        let identifier = NSUserInterfaceItemIdentifier("MessageCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? MessageTableCell
          ?? MessageTableCell()
        cell.identifier = identifier
        cell.setDependencies(dependencies)

        let inputProps = messageProps(for: row)

        let (_, _, _, layoutPlan) = sizeCalculator.calculateSize(
          for: message,
          with: inputProps,
          tableWidth: tableWidth()
        )

        let props = MessageViewProps(
          firstInGroup: inputProps.firstInGroup,
          isLastMessage: inputProps.isLastMessage,
          isFirstMessage: inputProps.isFirstMessage,
          isRtl: inputProps.isRtl,
          isDM: chat?.type == .privateChat,
          index: messageIndex,
          translated: inputProps.translated,
          layout: layoutPlan
        )

        cell.setScrollState(scrollState)
        cell.configure(with: message, props: props, animate: animateUpdates)

        return cell
    }
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    guard let item = rowItem(at: row) else {
      return defaultRowHeight
    }
    #if DEBUG
    log.trace("Noting height change for row \(row)")
    #endif

    switch item {
      case .daySeparator:
        return DateSeparatorTableCell.height

      case let .message(id):
        guard let messageIndex = messageIndexById[id], messages.indices.contains(messageIndex) else {
          return defaultRowHeight
        }
        let message = messages[messageIndex]
        let props = messageProps(for: row)
        let tableWidth = ceil(tableView.bounds.width)

        let (_, _, _, plan) = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth)

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

  func scrollToMsgAndHighlight(_ msgId: Int64) {
    // Don't allow negative msgIds (likely local messages)
    guard msgId > 0 else { return }

    if messages.isEmpty {
      log.error("No messages to scroll to")
      return
    }

    guard let messageIndex = messages.firstIndex(where: { $0.message.messageId == msgId }) else {
      log.error("Message not found for id \(msgId)")

      // TODO: Load more to get to it
      if let first = messages.first, first.message.messageId > msgId {
        log
          .debug(
            "Loading batch at top to find message because first message id = \(first.message.messageId) and what we want is \(msgId)"
          )
        loadBatch(at: .older)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
          self?.scrollToMsgAndHighlight(msgId)
        }
      } else {
        log.error("Message not found for id even after loading all messages from cache \(msgId)")
      }
      return
    }

    let stableId = messages[messageIndex].id
    guard let row = rowIndexByMessageId[stableId] else {
      log.error("Row not found for stable message id \(stableId)")
      return
    }

    // Get current scroll position and target position
    let currentY = scrollView.contentView.bounds.origin.y
    let targetRect = tableView.rect(ofRow: row)
    let viewportHeight = scrollView.contentView.bounds.height
    let targetY = max(0, targetRect.midY - (viewportHeight / 2))

    // Calculate distance to scroll
    let distance = abs(targetY - currentY)

    // Prepare for animation
    isProgrammaticScroll = true

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
        // Phase 2: Slow down for final approach
        NSAnimationContext.runAnimationGroup { [weak self] context in
          context.duration = 0.4
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)

          // Final scroll to target
          self?.scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
        } completionHandler: { [weak self] in
          // Clean up
          self?.isProgrammaticScroll = false

          self?.highlightMessage(at: row)
        }
      }
    } else {
      // For short distances, use a single smooth animation
      NSAnimationContext.runAnimationGroup { [weak self] context in
        context.duration = 0.4
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        self?.scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
      } completionHandler: { [weak self] in
        // Clean up
        self?.isProgrammaticScroll = false

        self?.highlightMessage(at: row)
      }
    }
  }

  private func highlightMessage(at row: Int) {
    // Verify row is still valid (tableView state may have changed during animation)
    guard row >= 0, row < tableView.numberOfRows else {
      log.debug("Cannot highlight message at row \(row) - tableView has \(tableView.numberOfRows) rows")
      return
    }

    guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCell else {
      return
    }
    cell.highlight()
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
    isProgrammaticScroll = true

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
          self?.isProgrammaticScroll = false

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
        self?.isProgrammaticScroll = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
          self?.enableScrollbars()
        }
      }
    }
  }

  // Define scroll position options
  enum ScrollPosition {
    case top
    case center
    case bottom
  }
}

extension MessageListAppKit {
  func dispose() {
    // Cancel any tasks
    eventMonitorTask?.cancel()
    eventMonitorTask = nil
    deferredTranslationTask?.cancel()
    deferredTranslationTask = nil

    // Remove all observers
    NotificationCenter.default.removeObserver(self)
    if let appActivityObserverId {
      AppActivityMonitor.shared.removeObserver(appActivityObserverId)
      self.appActivityObserverId = nil
    }

    // Clear all callbacks
    scrollToBottomButton.onClick = nil

    // Dispose view model
    viewModel.dispose()

    // Clear table view delegates
    tableView.delegate = nil
    tableView.dataSource = nil

    // Remove from parent if still attached
    view.removeFromSuperview()
    removeFromParent()

    Log.shared.debug("🗑️🧹 MessageListAppKit disposed: \(self)")
  }
}
