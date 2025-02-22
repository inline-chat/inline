import AppKit
import InlineKit
import Logger
import SwiftUI

class MessageListAppKit: NSViewController {
  // Data
  private var peerId: Peer
  private var chat: Chat?
  private var chatId: Int64 { chat?.id ?? 0 }
  private var viewModel: MessagesProgressiveViewModel
  private var messages: [FullMessage] { viewModel.messages }

  private let log = Log.scoped("MessageListAppKit", enableTracing: true)
  private let sizeCalculator = MessageSizeCalculator.shared
  private let defaultRowHeight = 24.0

  // Specification - mostly useful in debug
  private var feature_scrollsToBottomOnNewMessage = true
  private var feature_setupsInsetsManually = true
  private var feature_updatesHeightsOnWidthChange = true
  private var feature_updatesHeightsOnLiveResizeEnd = true
  private var feature_recalculatesHeightsWhileInitialScroll = true
  private var feature_loadsMoreWhenApproachingTop = true

  // Testing
  private var feature_scrollsToBottomInDidLayout = true
  private var feature_maintainsScrollFromBottomOnResize = true

  // Not needed
  private var feature_updatesHeightsOnOffsetChange = false

  // Debugging
  private var debug_slowAnimation = false

  init(peerId: Peer, chat: Chat?) {
    self.peerId = peerId
    self.chat = chat
    viewModel = MessagesProgressiveViewModel(peer: peerId)

    super.init(nibName: nil, bundle: nil)

    viewModel.observe { [weak self] update in
      self?.applyUpdate(update)

      DispatchQueue.main.async {
        self?.updateUnreadIfNeeded()
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private lazy var tableView: NSTableView = {
    let table = NSTableView()
    table.style = .plain
    table.backgroundColor = .clear
//    table.backgroundColor = .windowBackgroundColor
    // table.backgroundColor = .controlBackgroundColor
    table.headerView = nil
    table.rowSizeStyle = .custom
    table.selectionHighlightStyle = .none
    table.intercellSpacing = NSSize(width: 0, height: 0)
    table.usesAutomaticRowHeights = false
    table.rowHeight = defaultRowHeight

    let column = NSTableColumn(identifier: .init("messageColumn"))
    column.isEditable = false
    column.resizingMask = .autoresizingMask // v important
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

  override func loadView() {
    view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    setupViews()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupScrollObserver()

    // Read messages
    readAll()
  }

  // MARK: - Insets

  private var insetForCompose: CGFloat = Theme.composeMinHeight
  public func updateInsetForCompose(_ inset: CGFloat) {
    insetForCompose = inset

    scrollView.withoutScrollerFlash {
      scrollView.contentInsets.bottom = Theme.messageListBottomInset + insetForCompose
      // TODO: make quick changes smoother. currently it jitters a little
      if isAtBottom {
        self.tableView.scrollToBottomWithInset()
      }
    }
  }

  private func setInsets() {
    // TODO: extract insets logic from bottom here.
  }

  // This fixes the issue with the toolbar messing up initial content insets on window open. Now we call it on did
  // layout and it fixes the issue.
  private func updateScrollViewInsets() {
    guard feature_setupsInsetsManually else { return }
    guard let window = view.window else { return }

    let windowFrame = window.frame
    let contentFrame = window.contentLayoutRect
    let toolbarHeight = windowFrame.height - contentFrame.height

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
//    let visibleRect = userVisibleRect()
//    let visibleRange = tableView.rows(in: visibleRect)
//
//    for row in visibleRange.location ..< visibleRange.location + visibleRange.length {
//      guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCell else {
//        return
//      }
//      let rect = tableView.rect(ofRow: row)
//
//      let fractionToTopOfViewport = (rect.minY - visibleRect.minY) / visibleRect.height
//
//      cell.reflectBoundsChange(fraction: fractionToTopOfViewport)
//    }
  }

  private func updateToolbar() {
    // make window toolbar layout and have background to fight the swiftui defaUlt behaviour
    guard let window = view.window else { return }
    log.trace("Adjusting view's toolbar")

    let atTop = isAtTop()
    window.titlebarAppearsTransparent = atTop
    window.isMovableByWindowBackground = true
    window.titlebarSeparatorStyle = .automatic
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
  }

  private func scrollToBottom(animated: Bool) {
    guard messages.count > 0 else { return }
    log.trace("Scrolling to bottom animated=\(animated)")

    isProgrammaticScroll = true
    defer { isProgrammaticScroll = false }

    scrollView.withoutScrollerFlash {
      if animated {
        // Causes clipping at the top
        NSAnimationContext.runAnimationGroup { context in
          context.duration = debug_slowAnimation ? 1.5 : 0.2
          context.allowsImplicitAnimation = true

          tableView.scrollToBottomWithInset()
          //        tableView.scrollRowToVisible(lastRow)
        }
      } else {
        //      CATransaction.begin()
        //      CATransaction.setDisableActions(true)
        tableView.scrollToBottomWithInset()
        //      tableView.scrollRowToVisible(lastRow)
        //      CATransaction.commit()

        // Test if this gives better performance than above solution
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0
          context.allowsImplicitAnimation = false
          tableView.scrollToBottomWithInset()
        }
      }
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
    isUserScrolling = true
    scrollState = .scrolling
  }

  @objc private func scrollWheelEnded() {
    isUserScrolling = false
    scrollState = .idle

    updateUnreadIfNeeded()
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
  private func fullWidthAsyncCalc() {
    precalculateHeightsInBackground()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      // Recalculate all height when user is done resizing
      self?.recalculateHeightsOnWidthChange(buffer: 400)
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
    isAtBottom = overScrolledToBottom || abs(currentScrollOffset - maxScrollableHeight) <= 5.0
    isAtAbsoluteBottom = overScrolledToBottom || abs(currentScrollOffset - maxScrollableHeight) <= 0.1

    if feature_updatesHeightsOnOffsetChange, isUserScrolling, !isPerformingUpdate,
       currentScrollOffset
       .truncatingRemainder(dividingBy: 5.0) ==
       0 // Picking a too high number for this will make it not fire enough... we need a better way
    {
      let _ = recalculateHeightsOnWidthChange()
    }

    // Check if we're approaching the top
    if feature_loadsMoreWhenApproachingTop, isUserScrolling, currentScrollOffset < viewportSize.height {
      loadBatch(at: .older)
    }

    updateToolbar()
    updateMessageViewColors()
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

    guard let documentView = scrollView.documentView else { return }

    if isPerformingUpdate {
      // Do not maintain scroll when performing update, TODO: Fix later
      return
    }

    log.trace("scroll view frame changed, maintaining scroll from bottom")

    let viewportSize = scrollView.contentView.bounds.size

    // DISABLED CHECK BECAUSE WIDTH CAN CHANGE THE MESSAGES
    // Only do this if frame height changed. Width is handled in another function
//    if abs(viewportSize.height - previousViewportHeight) < 0.1 {
//      return
//    }

    let scrollOffset = scrollView.contentView.bounds.origin
    let contentSize = scrollView.documentView?.frame.size ?? .zero

    log
      .trace(
        "scroll view frame changed, maintaining scroll from bottom \(contentSize.height) \(previousViewportHeight)"
      )
    previousViewportHeight = viewportSize.height

    // TODO: min max
    let nextScrollPosition = contentSize.height - (oldDistanceFromBottom + viewportSize.height)

    if nextScrollPosition == scrollOffset.y {
      log.trace("scroll position is same, skipping maintaining")
      return
    }

    // Early return if no change needed
    if abs(nextScrollPosition - scrollOffset.y) < 0.5 { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Set new scroll position
    documentView.scroll(NSPoint(x: 0, y: nextScrollPosition))
    CATransaction.commit()

    //    Looked a bit laggy to me
//    NSAnimationContext.runAnimationGroup { context in
//      context.duration = 0
//      context.allowsImplicitAnimation = false
//      documentView.scroll(NSPoint(x: 0, y: nextScrollPosition))
//    }
  }

  private var lastKnownWidth: CGFloat = 0
  private var needsInitialScroll = true

  override func viewDidLayout() {
    super.viewDidLayout()
    log.trace("viewDidLayout() called")
    updateScrollViewInsets()
    checkWidthChangeForHeights()
    updateToolbar()
    updateMessageViewColors()

    // Initial scroll to bottom
    if needsInitialScroll {
      if feature_recalculatesHeightsWhileInitialScroll {
        // Note(@mo): I still don't know why this fixes it but as soon as I compare the widths for the change,
        // it no longer works. this needs to be called unconditionally.
        // this is needed to ensure the scroll is done after the initial layout and prevents cutting off last msg
        // EXPERIMENTAL: GETTING RID OF THIS FOR PERFORMANCE REASONS
        // let _ = recalculateHeightsOnWidthChange()
      }

      scrollToBottom(animated: false)

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { // EXPERIMENTAL: DECREASED FROM 0.1
        // Finalize heights one last time to ensure no broken heights on initial load
        self.needsInitialScroll = false

        // One last stabilizer (bc we disabled the recalc above, things above viewport might be stuck)
        self.fullWidthAsyncCalc()
      }
    }

    if feature_scrollsToBottomInDidLayout {
      // Note(@mo): This is a hack to fix scroll jumping when user is resizing the window at bottom.
      if isAtAbsoluteBottom, !isPerformingUpdate {
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

    log.trace("Checking width change, diff = \(abs(tableView.bounds.width - lastKnownWidth))")
    let newWidth = tableView.bounds.width

    // Using this prevents an issue where cells height was stuck in a cut off way when using
    // MessageSizeCalculator.safeAreaWidth as the diff
    // let magicWidthDiff = 15.0

    // Experimental
    let magicWidthDiff = 1.0

    if abs(newWidth - lastKnownWidth) > magicWidthDiff {
      lastKnownWidth = newWidth

      /// Below used to check if width is above max width to not calculate anything, but
      /// this results in very subtle bugs, eg. when window was smaller, then increased width beyond max (so the
      /// calculations are paused, then increases height. now the recalc doesn't happen for older messages.

      let availableWidth = sizeCalculator.getAvailableWidth(
        tableWidth: tableWidth()
      )
      if availableWidth < Theme.messageMaxWidth {
        recalculateHeightsOnWidthChange(duringLiveResize: true)
        wasLastResizeAboveLimit = false
      } else {
        if !wasLastResizeAboveLimit {
          // One last time just before stopping at the limit. This is import so stuff don't get stuck
          recalculateHeightsOnWidthChange(duringLiveResize: true)
          wasLastResizeAboveLimit = true
        } else {
          log.trace("skipped width recalc")
        }
      }
    }
  }

  private var loadingBatch = false

  // Currently only at top is supported.
  func loadBatch(at direction: MessagesProgressiveViewModel.MessagesLoadDirection) {
    if direction != .older { return }
    if loadingBatch { return }
    loadingBatch = true

    Task {
      // Preserve scroll position from bottom if we're loading at top
      maintainingBottomScroll {
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
        NSAnimationContext.runAnimationGroup { context in
          context.duration = animationDuration
          self.tableView.insertRows(at: IndexSet(indexSet), withAnimation: .effectFade)
          if shouldScroll { self.scrollToBottom(animated: true) }
        } completionHandler: {
          self.isPerformingUpdate = false
        }

      case let .deleted(_, indexSet):
        NSAnimationContext.runAnimationGroup { context in
          context.duration = animationDuration
          self.tableView.removeRows(at: IndexSet(indexSet), withAnimation: .effectFade)
          if shouldScroll { self.scrollToBottom(animated: true) }
        } completionHandler: {
          self.isPerformingUpdate = false
        }

      case let .updated(_, indexSet):
        tableView
          .reloadData(forRowIndexes: IndexSet(indexSet), columnIndexes: IndexSet([0]))
        if shouldScroll { scrollToBottom(animated: true) }
        isPerformingUpdate = false
      //      NSAnimationContext.runAnimationGroup { context in
      //        context.duration = animationDuration
      //        self.tableView
      //          .reloadData(forRowIndexes: IndexSet(indexSet), columnIndexes: IndexSet([0]))
      //        if shouldScroll { self.scrollToBottom(animated: true) } // ??
      //      } completionHandler: {
      //        self.isPerformingUpdate = false
      //      }

      case .reload:
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

    log.trace("Maintaining scroll from bottom, oldOffset=\(currentOffset), newOffset=\(newOffset)")

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
    log.debug("Anchoring to bottom. Visible rect: \(visibleRectInsetted) inset: \(bottomInset)")

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
        log.debug("""
                Anchoring to bottom row: \(index), 
                distance: \(topEdgeToViewportBottom)  
                row.minY=\(rowRect.minY) 
                row.maxY=\(rowRect.maxY)  
                row.height=\(rowRect.height) 
                visibleRect.minY=\(visibleRect.minY)
                visibleRect.maxY=\(visibleRect.maxY)  
        """)
    }

    return {
      self.scrollView.layoutSubtreeIfNeeded()

      switch anchor {
        case let .bottom(row, distanceFromViewportBottom):
          // Get the updated rect for the anchor row
          let rowRect = self.tableView.rect(ofRow: row)

          // Calculate new scroll position to maintain the same distance from viewport bottom
          let viewportHeight = self.scrollView.contentView.bounds.height
          let targetY = rowRect.minY - viewportHeight - distanceFromViewportBottom

          // Apply new scroll position
          let newOrigin = CGPoint(x: 0, y: targetY)

          self.scrollView.withoutScrollerFlash {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.scrollView.contentView.scroll(newOrigin)
            CATransaction.commit()
          }
      }
    }
  }

  // Note this function will stop any animation that is happening so must be used with caution
  // increasing buffer results in unstable scroll if not maintained
  private func recalculateHeightsOnWidthChange(buffer: Int = 0, duringLiveResize: Bool = false) {
    log.trace("Recalculating heights on width change")

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
    let visibleIndexesToUpdate = IndexSet(integersIn: visibleStartIndex ..< visibleEndIndex)

    var rowsToUpdate = IndexSet()

    if duringLiveResize {
      // Find which rows are shorter than available width
      let availableWidth = sizeCalculator.getAvailableWidth(
        tableWidth: tableView.bounds.width
      )

      for row in visibleStartIndex ..< visibleEndIndex {
        if let message = message(forRow: row), !sizeCalculator
          .isSingleLine(message, availableWidth: availableWidth)
        {
          rowsToUpdate.insert(row)
        }
      }

    } else {
      // Update all regardless of width
      // Why? Less optimized but quickly fixes a bug where items that crossed the threshold out of viewport, don't
      // update
      // even when we scroll to them.
      rowsToUpdate = visibleIndexesToUpdate
    }

    log.trace("Rows to update: \(rowsToUpdate)")
    let apply: (() -> Void)? = if !duringLiveResize { anchorScroll(to: .bottomRow) } else { nil }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      context.allowsImplicitAnimation = false

      self.tableView.beginUpdates()
      // Update heights in cells and setNeedsDisplay
      updateHeightsForRows(at: rowsToUpdate)

      // Experimental: noteheight of rows was below reload data initially
      self.tableView.noteHeightOfRows(withIndexesChanged: rowsToUpdate)
      self.tableView.endUpdates()

      apply?()
    }
  }

  private func updateHeightsForRows(at indexSet: IndexSet) {
    for row in indexSet {
      if let rowView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageTableCell {
        var props = messageProps(for: row)
        if let message = message(forRow: row) {
          let (_, textSize, photoSize) = sizeCalculator.calculateSize(
            for: message,
            with: props,
            tableWidth: tableWidth()
          )
          props.photoWidth = photoSize?.width
          props.photoHeight = photoSize?.height
          props.textWidth = textSize.width
          props.textHeight = textSize.height
          rowView.updateTextAndSizeWithProps(props: props)
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

    Task(priority: .userInitiated) {
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

  private func messageProps(for row: Int) -> MessageViewProps {
    guard row >= 0, row < messages.count else {
      return MessageViewProps(
        firstInGroup: true,
        isLastMessage: true,
        isFirstMessage: true,
        isRtl: false
      )
    }

    let message = messages[row]
    return MessageViewProps(
      firstInGroup: isFirstInGroup(at: row),
      isLastMessage: isLastMessage(at: row),
      isFirstMessage: isFirstMessage(at: row),
      isRtl: false
    )
  }

  private func calculateNewHeight(forRow row: Int) -> CGFloat {
    guard row >= 0, row < messages.count else {
      return defaultRowHeight
    }

    let message = messages[row]
    let props = messageProps(for: row)

    let (size, _, _) = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth())
    return size.height
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Unread

  func readAll() {
    UnreadManager.shared.readAll(peerId, chatId: chatId)
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
}

extension MessageListAppKit: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    messages.count
  }
}

extension MessageListAppKit: NSTableViewDelegate {
  func isFirstInGroup(at row: Int) -> Bool {
    guard row >= 0, row < messages.count else { return true }

    let prevMessage = row > 0 ? messages[row - 1] : nil
    guard prevMessage != nil else {
      return true
    }

    if prevMessage?.message.fromId != messages[row].message.fromId {
      return true
    }

    if messages[row].message.date.timeIntervalSince(prevMessage!.message.date) > 60 * 5 {
      return true
    }

    return false
  }

  func isLastMessage(at row: Int) -> Bool {
    guard row >= 0, row < messages.count else { return true }
    return row == messages.count - 1
  }

  func isFirstMessage(at row: Int) -> Bool {
    row == 0
  }

  /// ceil'ed table width.
  /// ceiling prevent subpixel differences in height calc passes which can cause jitter
  private func tableWidth() -> CGFloat {
    ceil(tableView.bounds.width)
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard row >= 0, row < messages.count else { return nil }
    log.trace("Making/using view for row \(row)")

    let message = messages[row]
    let identifier = NSUserInterfaceItemIdentifier("MessageCell")

    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? MessageTableCell
      ?? MessageTableCell()
    cell.identifier = identifier

    var props = messageProps(for: row)

    let (_, textSize, photoSize) = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth())

    props.textWidth = textSize.width
    props.textHeight = textSize.height

    props.photoWidth = photoSize?.width
    props.photoHeight = photoSize?.height

    props.index = row

    cell.configure(with: message, props: props)
    return cell
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    guard row >= 0, row < messages.count else {
      return defaultRowHeight
    }
    log.trace("Noting height change for row \(row)")

    let message = messages[row]

    var height: CGFloat = 0.0

    let props = messageProps(for: row)

    let tableWidth = ceil(tableView.bounds.width)

    let (size, _, _) = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth)
    height = size.height

    return height
  }
}

extension NSTableView {
  func scrollToBottomWithInset() {
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

    // scrollView.contentView.scroll(targetPoint)
    scrollView.documentView?.scroll(targetPoint)

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
}
