import AppKit
import InlineKit
import Logger
import SwiftUI
import Throttler

class MessageListAppKit: NSViewController {
  // Data
  private var dependencies: AppDependencies
  private var peerId: Peer
  private var chat: Chat?
  private var chatId: Int64 { chat?.id ?? 0 }
  private var viewModel: MessagesProgressiveViewModel
  private var messages: [FullMessage] { viewModel.messages }
  private var state: ChatState

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

  private var eventMonitorTask: Task<Void, Never>?

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

    super.init(nibName: nil, bundle: nil)

    sizeCalculator.prepareForUse()

    // observe data
    viewModel.observe { [weak self] update in
      self?.applyUpdate(update)

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
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private lazy var toolbarBgView: NSVisualEffectView = ChatToolbarView(dependencies: dependencies)

  private func toggleToolbarVisibility(_ hide: Bool) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.08
      context.allowsImplicitAnimation = true

      toolbarBgView.alphaValue = hide ? 0 : 1
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

    // Read messages
    // readAll()
  }

  // MARK: - Insets

  private var insetForCompose: CGFloat = Theme.composeMinHeight
  public func updateInsetForCompose(_ inset: CGFloat, animate: Bool = true) {
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

  private var toolbarHeight: CGFloat = 52

  // This fixes the issue with the toolbar messing up initial content insets on window open. Now we call it on did
  // layout and it fixes the issue.
  private func updateScrollViewInsets() {
    guard feature_setupsInsetsManually else { return }
    guard let window = view.window else { return }

    let windowFrame = window.frame
    let contentFrame = window.contentLayoutRect
    let toolbarHeight = windowFrame.height - contentFrame.height
    self.toolbarHeight = toolbarHeight

    if scrollView.contentInsets.top != toolbarHeight {
      log.trace("Adjusting view's insets")

      scrollView.contentInsets = NSEdgeInsets(
        top: toolbarHeight,
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
    }
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

  private func updateMessageViewColors() {
  }

  private var isToolbarVisible = false

  private func updateToolbar() {
    // make window toolbar layout and have background to fight the swiftui defaUlt behaviour
    guard let window = view.window else { return }
    log.trace("Adjusting view's toolbar")

    let atTop = isAtTop()
    isToolbarVisible = !atTop
    // window.titlebarAppearsTransparent = atTop
//    window.titlebarAppearsTransparent = true
//    window.titlebarSeparatorStyle = .automatic
//    window.isMovableByWindowBackground = false

    toggleToolbarVisibility(atTop)
  }

  private func setupViews() {
    view.addSubview(scrollView)
    view.addSubview(toolbarBgView)

    // Set up constraints
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      toolbarBgView.topAnchor.constraint(equalTo: view.topAnchor),
      toolbarBgView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      toolbarBgView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      toolbarBgView.heightAnchor.constraint(equalToConstant: toolbarHeight),
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
    guard messages.count > 0 else { return }
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
        let prevCount = viewModel.messages.count
        viewModel.loadBatch(at: direction)
        let newCount = viewModel.messages.count
        let diff = newCount - prevCount

        if diff > 0 {
          let newIndexes = IndexSet(0 ..< diff)
          tableView.beginUpdates()
          tableView.insertRows(at: newIndexes, withAnimation: .none)
          tableView.endUpdates()

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
    tableView.reloadData()
  }

  func applyUpdate(_ update: MessagesProgressiveViewModel.MessagesChangeSet) {
    isPerformingUpdate = true

    // using "atBottom" here might add jitter if user is scrolling slightly up and then we move it down quickly
    let wasAtBottom = isAtAbsoluteBottom
    let animationDuration = debug_slowAnimation ? 1.5 : 0.15
    let shouldScroll = wasAtBottom && feature_scrollsToBottomOnNewMessage &&
      !isUserScrolling // to prevent jitter when user is scrolling

    switch update {
      case let .added(_, indexSet):
        log.trace("applying add changes")

        // Note: we don't need to begin/end updates here as it's a single operation
        NSAnimationContext.runAnimationGroup { [weak self] context in
          guard let self else { return }
          context.duration = animationDuration
          tableView.insertRows(at: IndexSet(indexSet), withAnimation: .effectFade)
          if shouldScroll { scrollToBottom(animated: true) }
        } completionHandler: { [weak self] in
          self?.isPerformingUpdate = false
        }

      case let .deleted(_, indexSet):
        for index in indexSet {
          if let message = message(forRow: index) {
            cellCache.removeCell(withType: "MessageCell", messageId: message.id)
          }
        }

        NSAnimationContext.runAnimationGroup { [weak self] context in
          guard let self else { return }
          context.duration = animationDuration
          tableView.removeRows(at: IndexSet(indexSet), withAnimation: .effectFade)
          if shouldScroll { scrollToBottom(animated: true) }
        } completionHandler: { [weak self] in
          self?.isPerformingUpdate = false
        }

      case let .updated(_, indexSet, animated):
        for index in indexSet {
          if let message = message(forRow: index) {
            cellCache.removeCell(withType: "MessageCell", messageId: message.id)
          }
        }

        if animated == true {
          NSAnimationContext.runAnimationGroup { [weak self] context in
            guard let self else { return }
            context.duration = animationDuration
            tableView
              .reloadData(forRowIndexes: IndexSet(indexSet), columnIndexes: IndexSet([0]))
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(indexSet))
            if shouldScroll { scrollToBottom(animated: true) } // ??
          } completionHandler: { [weak self] in
            self?.isPerformingUpdate = false
          }
        } else {
          tableView
            .reloadData(forRowIndexes: IndexSet(indexSet), columnIndexes: IndexSet([0]))
          if shouldScroll { scrollToBottom(animated: true) }
          isPerformingUpdate = false
        }

      case .reload:
        cellCache.clearCache()
        log.trace("reloading data")
        tableView.reloadData()
        if shouldScroll { scrollToBottom(animated: false) }
        isPerformingUpdate = false
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
            index: row,
            layout: plan
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
    guard row >= 0, row < messages.count else {
      return nil
    }

    return messages[row]
  }

  private func getCachedSize(forRow row: Int) -> CGSize? {
    guard row >= 0, row < messages.count else {
      return nil
    }

    let message = messages[row]
    return sizeCalculator.cachedSize(messageStableId: message.id)
  }

  private func messageProps(for row: Int) -> MessageViewInputProps {
    guard row >= 0, row < messages.count else {
      return MessageViewInputProps(
        firstInGroup: true,
        isLastMessage: true,
        isFirstMessage: true,
        isDM: chat?.type == .privateChat,
        isRtl: false
      )
    }

    let message = messages[row]
    return MessageViewInputProps(
      firstInGroup: isFirstInGroup(at: row),
      isLastMessage: isLastMessage(at: row),
      isFirstMessage: isFirstMessage(at: row),
      isDM: chat?.type == .privateChat,
      isRtl: false
    )
  }

  private func calculateNewHeight(forRow row: Int) -> CGFloat {
    guard row >= 0, row < messages.count else {
      return defaultRowHeight
    }

    let message = messages[row]
    let props = messageProps(for: row)

    let (_, _, _, plan) = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth())
    return plan.totalHeight
  }

  deinit {
    dispose()

    Log.shared.debug("🗑️ Deinit: \(type(of: self)) - \(self)")
  }

  // MARK: - Unread

  func readAll() {
    Task {
      UnreadManager.shared.readAll(peerId, chatId: chatId)
    }
  }

  func updateUnreadIfNeeded() {
    // Quicker check
    if isAtBottom {
      readAll()
      return
    }

    let visibleRect = tableView.visibleRect
    let visibleRange = tableView.rows(in: visibleRect)
    let maxRow = tableView.numberOfRows - 1
    let isLastRowVisible = visibleRange.location + visibleRange.length >= maxRow

    if isLastRowVisible {
      readAll()
    }
  }

  private let cellCache = TableViewCellCache<MessageTableCell>(maxCacheSize: 200)
}

extension MessageListAppKit: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    messages.count
  }
}

extension MessageListAppKit: NSTableViewDelegate {
  func isFirstInGroup(at row: Int) -> Bool {
    guard messages.indices.contains(row) else { return true }
    guard row > 0 else { return true }

    let current = messages[row]
    let previous = messages[row - 1]

    return previous.message.fromId != current.message.fromId ||
      current.message.date.timeIntervalSince(previous.message.date) > 300
  }

  func isLastMessage(at row: Int) -> Bool {
    row == messages.count - 1
  }

  func isFirstMessage(at row: Int) -> Bool {
    row == 0
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
    guard row >= 0, row < messages.count else { return nil }

    #if DEBUG
    log.trace("Making/using view for row \(row)")
    #endif

    let message = messages[row]

    let identifier = NSUserInterfaceItemIdentifier("MessageCell")
    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? MessageTableCell
      ?? MessageTableCell()
    cell.identifier = identifier

    let inputProps = messageProps(for: row)

    let (_, _, _, layoutPlan) = sizeCalculator.calculateSize(for: message, with: inputProps, tableWidth: tableWidth())

    let props = MessageViewProps(
      firstInGroup: inputProps.firstInGroup,
      isLastMessage: inputProps.isLastMessage,
      isFirstMessage: inputProps.isFirstMessage,
      isRtl: inputProps.isRtl,
      isDM: chat?.type == .privateChat,
      index: row,
      layout: layoutPlan
    )

    cell.setScrollState(scrollState)
    cell.configure(with: message, props: props, animate: animateUpdates)

    // Store the configured cell in cache
    // cellCache.cacheCell(cell, withType: "MessageCell", messageId: message.id)

    return cell
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    guard row >= 0, row < messages.count else {
      return defaultRowHeight
    }
    #if DEBUG
    log.trace("Noting height change for row \(row)")
    #endif

    let message = messages[row]
    let props = messageProps(for: row)
    let tableWidth = ceil(tableView.bounds.width)

    let (_, _, _, plan) = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth)

    return plan.totalHeight
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
    if messages.isEmpty {
      log.error("No messages to scroll to")
      return
    }

    guard let index = messages.firstIndex(where: { $0.message.messageId == msgId }) else {
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

    // Get current scroll position and target position
    let currentY = scrollView.contentView.bounds.origin.y
    let targetRect = tableView.rect(ofRow: index)
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

          self?.highlightMessage(at: index)
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

        self?.highlightMessage(at: index)
      }
    }
  }

  private func highlightMessage(at row: Int) {
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

    // Remove all observers
    NotificationCenter.default.removeObserver(self)

    // Clear all callbacks
    scrollToBottomButton.onClick = nil

    // Dispose view model
    viewModel.dispose()

    // Clear table view delegates
    tableView.delegate = nil
    tableView.dataSource = nil

    // Clear cell cache
    cellCache.clearCache()

    // Remove from parent if still attached
    view.removeFromSuperview()
    removeFromParent()

    Log.shared.debug("🗑️🧹 MessageListAppKit disposed: \(self)")
  }
}
