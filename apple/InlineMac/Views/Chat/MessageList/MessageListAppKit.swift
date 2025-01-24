import AppKit
import InlineKit
import SwiftUI

class MessageListAppKit: NSViewController {
  // Data
  private var peerId: Peer
  private var viewModel: MessagesProgressiveViewModel
  private var messages: [FullMessage] { viewModel.messages }

  private let log = Log.scoped("MessageListAppKit", enableTracing: true)
  private let sizeCalculator = MessageSizeCalculator.shared
  private let defaultRowHeight = 24.0

  // Specification - mostly useful in debug
  private var feature_scrollsToBottomOnNewMessage = true
  private var feature_scrollsToBottomInDidLayout = true
  private var feature_setupsInsetsManually = true
  private var feature_updatesHeightsOnWidthChange = true
  private var feature_updatesHeightsOnLiveResizeEnd = true
  private var feature_recalculatesHeightsWhileInitialScroll = true
  private var feature_loadsMoreWhenApproachingTop = true

  private var feature_maintainsScrollFromBottomOnResize = true
  private var feature_updatesHeightsOnOffsetChange = false

  // Debugging
  private var debug_slowAnimation = false

  init(peerId: Peer) {
    self.peerId = peerId
    viewModel = MessagesProgressiveViewModel(peer: peerId)

    super.init(nibName: nil, bundle: nil)

    viewModel.observe { [weak self] update in
      self?.applyUpdate(update)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private lazy var tableView: NSTableView = {
    let table = NSTableView()
    table.style = .plain
    table.backgroundColor = .controlBackgroundColor
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
    //    table.autoresizingMask = []
    table.delegate = self
    table.dataSource = self

    // Optimize performance
    table.wantsLayer = true
    table.layerContentsRedrawPolicy = .onSetNeedsDisplay
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
      scrollView.contentInsets = NSEdgeInsets(
        top: toolbarHeight,
        left: 0,
        bottom: Theme.messageListBottomInset + insetForCompose,
        right: 0)
      scrollView.scrollerInsets = NSEdgeInsets(
        top: 0,
        left: 0,
        bottom: -Theme.messageListBottomInset, // Offset it to touch bottom
        right: 0)

      log.debug("Adjusting view's toolbar")
      // make window toolbar layout and have background to fight the swiftui defaUlt behaviour
      window.titlebarAppearsTransparent = false
      window.isMovableByWindowBackground = true
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
      object: scrollView.contentView)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollViewBoundsChanged),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView)

    // Add scroll wheel notification
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollWheelBegan),
      name: NSScrollView.willStartLiveScrollNotification,
      object: scrollView)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollWheelEnded),
      name: NSScrollView.didEndLiveScrollNotification,
      object: scrollView)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(liveResizeEnded),
      name: NSWindow.didEndLiveResizeNotification,
      object: scrollView.window)
  }

  private var scrollState: MessageListScrollState = .idle {
    didSet {
      NotificationCenter.default.post(
        name: .messageListScrollStateDidChange,
        object: self,
        userInfo: ["state": scrollState])
    }
  }

  @objc private func scrollWheelBegan() {
    isUserScrolling = true
    scrollState = .scrolling
  }

  @objc private func scrollWheelEnded() {
    isUserScrolling = false
    scrollState = .idle
  }

  // Recalculate heights for all items once resize has ended
  @objc private func liveResizeEnded() {
    guard feature_updatesHeightsOnLiveResizeEnd else { return }

    // Recalculate all height when user is done resizing
    recalculateHeightsOnWidthChange(buffer: 400)
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

    let scrollOffset = scrollView.contentView.bounds.origin
    let viewportSize = scrollView.contentView.bounds.size
    let contentSize = scrollView.documentView?.frame.size ?? .zero

    // Only do this if frame height changed. Width is handled in another function
    if abs(viewportSize.height - previousViewportHeight) < 0.1 {
      return
    }
    log
      .trace(
        "scroll view frame changed, maintaining scroll from bottom \(contentSize.height) \(previousViewportHeight)")
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
    //      documentView.scroll(NSPoint(x: 0, y: nextScrollPosition))
    //    }
  }

  private var lastKnownWidth: CGFloat = 0
  private var needsInitialScroll = true

  override func viewDidAppear() {
    super.viewDidAppear()
    updateScrollViewInsets()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    updateScrollViewInsets()
    checkWidthChangeForHeights()

    // Initial scroll to bottom
    if needsInitialScroll {
      if feature_recalculatesHeightsWhileInitialScroll {
        // Note(@mo): I still don't know why this fixes it but as soon as I compare the widths for the change,
        // it no longer works. this needs to be called unconditionally.
        // this is needed to ensure the scroll is done after the initial layout and prevents cutting off last msg
        let _ = recalculateHeightsOnWidthChange()
      }

      scrollToBottom(animated: false)

      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        // Finalize heights one last time to ensure no broken heights on initial load
        self.needsInitialScroll = false
      }
    }

    if feature_scrollsToBottomInDidLayout {
      // Note(@mo): This is a hack to fix scroll jumping when user is resizing the window at bottom.
      if isAtAbsoluteBottom, !isPerformingUpdate {
        scrollToBottom(animated: false)
      }
    }
  }

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

      let availableWidth = sizeCalculator.getAvailableWidth(
        tableWidth: tableView.bounds.width)

      if availableWidth < Theme.messageMaxWidth {
        // Update heights
//        maintainingBottomScroll { // This ensures the scroll will not jump while resizing a multi-line message
//          recalculateHeightsOnWidthChange
//          return true
//        }

        recalculateHeightsOnWidthChange(duringLiveResize: true)
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
      height: visibleRect.height - bottomInset)
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
      visibleRange.location + visibleRange.length + buffer)

    if visibleStartIndex >= visibleEndIndex {
      return
    }

    // First, immediately update visible rows
    let visibleIndexesToUpdate = IndexSet(integersIn: visibleStartIndex ..< visibleEndIndex)

    var rowsToUpdate = IndexSet()

    if duringLiveResize {
      // Find which rows are shorter than available width
      let availableWidth = sizeCalculator.getAvailableWidth(
        tableWidth: tableView.bounds.width)

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
    let apply = anchorScroll(to: .bottomRow)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      context.allowsImplicitAnimation = false

      // Experimental: noteheight of rows was below reload data initially
      tableView.noteHeightOfRows(withIndexesChanged: rowsToUpdate)

      tableView
        .reloadData(
          forRowIndexes: rowsToUpdate,
          columnIndexes: IndexSet([0]))

      apply()
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

  private func calculateNewHeight(forRow row: Int) -> CGFloat {
    guard row >= 0, row < messages.count else {
      return defaultRowHeight
    }

    let message = messages[row]
    let props = MessageViewProps(
      firstInGroup: isFirstInGroup(at: row),
      isLastMessage: isLastMessage(at: row),
      isFirstMessage: isFirstMessage(at: row),
      isRtl: false)

    let tableWidth = tableView.bounds.width
    let (size, _, _) = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth)
    return size.height
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
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

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard row >= 0, row < messages.count else { return nil }

    let message = messages[row]
    let identifier = NSUserInterfaceItemIdentifier("MessageCell")

    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? MessageTableCell
      ?? MessageTableCell()
    cell.identifier = identifier

    var props = MessageViewProps(
      firstInGroup: isFirstInGroup(at: row),
      isLastMessage: isLastMessage(at: row),
      isFirstMessage: isFirstMessage(at: row),
//      isRtl: message.message.text?.isRTL ?? false
      // TODO: optimize
      isRtl: false)

    let tableWidth = tableView.bounds.width
    let (_, textSize, photoSize) = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth)

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

    let message = messages[row]

    let props = MessageViewProps(
      firstInGroup: isFirstInGroup(at: row),
      isLastMessage: isLastMessage(at: row),
      isFirstMessage: isFirstMessage(at: row),
//      isRtl: message.message.text?.isRTL ?? false
      // TODO: optimize
      isRtl: false)

    let tableWidth = tableView.bounds.width

    let (size, _, _) = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth)
    return size.height
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
      y: maxVisibleY + bottomInset - scrollView.contentView.bounds.height)

    scrollView.contentView.scroll(targetPoint)

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
