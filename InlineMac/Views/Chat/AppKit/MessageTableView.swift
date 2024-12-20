// MessagesViewController.swift
import AppKit
import InlineKit
import SwiftUI

class MessagesTableView: NSViewController {
  var width: CGFloat
  
  private let log = Log.scoped("MessagesTableView", enableTracing: true)
  private var messages: [FullMessage] = []
  private let sizeCalculator = MessageSizeCalculator()
  private let defaultRowHeight = 24.0
  
  init(width: CGFloat) {
    self.width = width
    super.init(nibName: nil, bundle: nil)
  }
  
  required init?(coder: NSCoder) {
    self.width = 0
    super.init(coder: coder)
  }
    
  private lazy var tableView: NSTableView = {
    let table = NSTableView()
    table.style = .plain
    table.backgroundColor = .clear
    table.headerView = nil
    table.rowSizeStyle = .custom
    table.selectionHighlightStyle = .none
    table.intercellSpacing = NSSize(width: 0, height: 0)
    table.usesAutomaticRowHeights = false
    table.rowHeight = defaultRowHeight
    table.layer?.backgroundColor = .clear
    
//    table.wantsLayer = true
//    table.layerContentsRedrawPolicy = .onSetNeedsDisplay
//    
    let column = NSTableColumn(identifier: .init("messageColumn"))
    column.isEditable = false
    column.resizingMask = .autoresizingMask

    table.addTableColumn(column)
    
    // Enable automatic resizing
    table.autoresizingMask = [.height]
    table.delegate = self
    table.dataSource = self
  
    return table
  }()
  
  private lazy var avatarOverlayView: AvatarOverlayView = {
    let manager = AvatarOverlayView(frame: .zero)
    manager.translatesAutoresizingMaskIntoConstraints = false
    return manager
  }()
  
  private lazy var scrollView: NSScrollView = {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = true // Add this line
    scroll.backgroundColor = .textBackgroundColor
//    scroll.backgroundColor = .windowBackgroundColor
    // Used for quick scroll on resize
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = tableView
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    
    scroll.verticalScrollElasticity = .allowed
    scroll.autohidesScrollers = true
    scroll.verticalScroller?.controlSize = .small // This makes it ultra-minimal

    scroll.postsBoundsChangedNotifications = true
    scroll.postsFrameChangedNotifications = true
    scroll.automaticallyAdjustsContentInsets = false
    
    return scroll
  }()
  
  override func loadView() {
    view = NSView()
    setupViews()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setupScrollObserver()
  }
  
  private var isScrolling = false
  private var lastUpdateTime: CFTimeInterval = 0

  private func updateAvatarsIfNeeded() {
    // Throttle updates during rapid scrolling
    let currentTime = CACurrentMediaTime()
    if isScrolling && (currentTime - lastUpdateTime) < 1.0 / 120.0 {
      return
    }
    lastUpdateTime = currentTime
    
    log.trace("updateAvatars in bounds changed")
    updateAvatars()
  }

  // This fixes the issue with the toolbar messing up initial content insets on window open. Now we call it on did layout and it fixes the issue.
  private func updateScrollViewInsets() {
    guard let window = view.window else { return }
    
    let windowFrame = window.frame
    let contentFrame = window.contentLayoutRect
    let toolbarHeight = windowFrame.height - contentFrame.height
    
    if scrollView.contentInsets.top != toolbarHeight {
      scrollView.contentInsets = NSEdgeInsets(
        top: toolbarHeight,
        left: 0,
        bottom: 0,
        right: 0
      )
      
      log.debug("Adjusting view's toolbar")
      // make window toolbar layout and have background to fight the swiftui defaUlt behaviour
      window.titlebarAppearsTransparent = false
      window.isMovableByWindowBackground = true
    }
  }
  
  private func setupViews() {
    view.addSubview(scrollView)
    view.addSubview(avatarOverlayView)
    
    // Set up constraints
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      
      avatarOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
      avatarOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.messageSidePadding),
      avatarOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      avatarOverlayView.widthAnchor.constraint(
        equalToConstant: AvatarOverlayView.size + Theme.messageSidePadding
      )
    ])
  }

  private func scrollToBottom(animated: Bool) {
    guard messages.count > 0 else { return }
    log.trace("Scrolling to bottom animated=\(animated)")
    
    let lastRow = messages.count - 1
    isProgrammaticScroll = true
    defer { isProgrammaticScroll = false }
    
    if animated {
      // Causes clipping at the top
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.allowsImplicitAnimation = true
        tableView.scrollRowToVisible(lastRow)
      }
    } else {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      tableView.scrollRowToVisible(lastRow)
      CATransaction.commit()
    }
  }

  private var lastContentHeight: CGFloat = 0
  
  // Add this property to track content size changes
  private var contentSizeObserver: NSKeyValueObservation?
  
  private func setupScrollObserver() {
    // Use direct observation for immediate response
    scrollView.contentView.postsFrameChangedNotifications = true
    scrollView.contentView.postsBoundsChangedNotifications = true
    
    // Observe document view's frame changes
    contentSizeObserver = scrollView.documentView?.observe(\.frame) { [weak self] view, _ in
      guard let self = self else { return }
      let newHeight = view.frame.height
      log.trace("scrollView document frame change")
      updateAvatars()
      
      handleContentSizeChange(newHeight)
    }
    
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(scrollViewFrameChanged),
                                           name: NSView.frameDidChangeNotification,
                                           object: scrollView.contentView)
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(scrollViewBoundsChanged),
                                           name: NSView.boundsDidChangeNotification,
                                           object: scrollView.contentView)
    
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

  @objc private func scrollWheelBegan() {
    isUserScrolling = true
  }
  
  @objc private func scrollWheelEnded() {
    isUserScrolling = false
  }

  private var isProgrammaticScroll = false
  private var isUserScrolling = false
  private var isAtBottom = true
  private var isAtAbsoluteBottom = true
  
  private var prevContentSize: CGSize = .zero
  private var isPerformingUpdate = false
  
  private func handleContentSizeChange(_ newHeight: CGFloat) {
    lastContentHeight = newHeight
    
    // Moved to didlayout
    if isAtBottom && (!isPerformingUpdate || needsInitialScroll) {
      log.trace("scrollView content size change")
      scrollToBottom(animated: false)
    }
  }
  
  private var prevOffset: CGFloat = 0
  
  @objc func scrollViewBoundsChanged(notification: Notification) {
    log.trace("scroll view bounds changed")
    
    // Update avatars as user scrolls
    //    updateAvatars()
    updateAvatarsIfNeeded()
    
    if needsInitialScroll {
      // reports inaccurate heights at this point
      return
    }
    
    let scrollOffset = scrollView.contentView.bounds.origin
    let viewportSize = scrollView.contentView.bounds.size
    let contentSize = scrollView.documentView?.frame.size ?? .zero
    let maxScrollableHeight = contentSize.height - viewportSize.height
    let currentScrollOffset = scrollOffset.y
    
    // Update scroll position
    let prevAtBottom = isAtBottom
    
//    DispatchQueue.main.async {
    // Prevent iaAtBottom false negative when elastic scrolling
    let overScrolledToBottom = currentScrollOffset > maxScrollableHeight
    isAtBottom = overScrolledToBottom || abs(currentScrollOffset - maxScrollableHeight) <= 5.0
    isAtAbsoluteBottom = overScrolledToBottom || abs(currentScrollOffset - maxScrollableHeight) <= 0.1
      
    #if DEBUG
      if isAtBottom != prevAtBottom {
        log.trace("isAtBottom changed. isAtBottom = \(isAtBottom) currentScrollOffset = \(currentScrollOffset) maxScrollableHeight = \(maxScrollableHeight)")
      }
    #endif
//    }

    // Only update width of rows if scrolling up otherwise this messes up scroll animation on new item
    if prevOffset != currentScrollOffset &&
      // this ensures bottom over scroll / elastic doesn't glitch bc of continuous update
      maxScrollableHeight > currentScrollOffset &&
      !isProgrammaticScroll && !isAtBottom &&
      prevOffset > currentScrollOffset &&
      // Debounce
      ceil(currentScrollOffset).truncatingRemainder(dividingBy: 10) == 0
    {
      // Update heights that might have been changed if a width change happened in a different position
      // because we just update visible portion of the table
      recalculateHeightsOnWidthChange()
    }
      
    prevOffset = currentScrollOffset
  }

  // Using CFAbsoluteTimeGetCurrent()
  private func measureTime(_ closure: () -> Void, name: String = "Function") {
    let start = CFAbsoluteTimeGetCurrent()
    closure()
    let end = CFAbsoluteTimeGetCurrent()
    let timeElapsed = (end - start) * 1000 // Convert to milliseconds
    log.trace("\(name) took \(String(format: "%.2f", timeElapsed))ms")
  }
  
  var avatarOverlay: AvatarOverlayView { avatarOverlayView }
  
  private func updateAvatars() {
    _updateAvatars()
  }
  
  private func _updateAvatars() {
    log.trace("update avatars")
    let stickyPadding: CGFloat = 8.0
    let scrollTopInset = scrollView.contentInsets.top
    let viewportHeight = scrollView.contentView.bounds.height
    let currentOffset = scrollView.contentView.bounds.origin.y
    let visibleRect = tableView.visibleRect
    let visibleRectMinusTopInset = visibleRect.offsetBy(dx: 0, dy: scrollTopInset)
    log.trace("Visible rect: \(visibleRect)")
    log.trace("Visible rect minus top inset: \(visibleRectMinusTopInset)")
    let visibleRange = tableView.rows(in: visibleRectMinusTopInset)
    guard visibleRange.location != NSNotFound else { return }
    guard visibleRange.length > 0 else { return }

    var processedRows = Set<Int>()
    
    // utils
    func avatarPadding(at row: Int) -> CGFloat {
      let padding = row == 0 ?
        Theme.messageListTopInset + Theme.messageVerticalPadding :
        Theme.messageVerticalPadding
      
      return padding + Theme.messageGroupSpacing
    }
    
    let availableViewportHeight = scrollView.contentView.bounds.height - scrollTopInset
    
    func avatarNaturalPosition(at row: Int) -> CGFloat {
      return viewportHeight - (tableView.rect(ofRow: row).minY - currentOffset) - AvatarOverlayView.size - avatarPadding(at: row)
    }
    
    // Find sticky avatars
    var stickyRow: Int? = nil
    var upcomingSticky: Int? = nil
    
    // sticky out of bound
    for row in (0...Int(visibleRange.location)).reversed() {
      if isFirstInGroup(at: row) {
        stickyRow = row
        break
      }
    }
   
    // top most avatar below sticky
    for row in Int(visibleRange.location) ..< Int(visibleRange.location + visibleRange.length) {
      // skip current sticky
      if isFirstInGroup(at: row) && row != stickyRow {
        upcomingSticky = row
        break
      }
    }
    
    // Get visible avatar rows
    let visibleAvatarRows = (Int(visibleRange.location)...Int(visibleRange.location + visibleRange.length))
      .filter { row in
        row < messages.count && isFirstInGroup(at: row)
      }
    
    // Handle sticky avatar
    if let primaryStickyRow = stickyRow {
      let message = messages[primaryStickyRow]
      
      // Calculate the natural position where avatar would be without any constraints
      let naturalPosition = avatarNaturalPosition(at: primaryStickyRow)
      
      // Min it with the viewport height - avatar size - padding so it doesn't go out of bounds of screen
      let stickyPosition = min(
        naturalPosition,
        availableViewportHeight - AvatarOverlayView.size - stickyPadding
      )
      
      // Find the first visible avatar below the sticky one, we need it so it pushes the sticky avatar up as it's about to overlap
      if let nextVisibleRow = upcomingSticky,
         // when fully overlap, ignore
         nextVisibleRow != primaryStickyRow
      {
        let nextAvatarPosition = avatarNaturalPosition(at: nextVisibleRow)
        // so it doesn't go above sticky padding immediately before becoming sticky and causing jump
        let nextAvatarPositionWithPadding = min(
          nextAvatarPosition,
          availableViewportHeight - AvatarOverlayView.size - stickyPadding
        )
        
        // Calculate the maximum allowed position (just above the next avatar)
        let maxAllowedPosition = nextAvatarPosition + AvatarOverlayView.size + stickyPadding
        
        // Use the higher position (more towards top of screen) between natural and pushed
        let stickyPositionWhenPushed = max(stickyPosition, maxAllowedPosition)
        
        log.trace("Sticky position: \(stickyPosition), pushed: \(stickyPositionWhenPushed), next: \(nextAvatarPosition), nextWithPadding: \(nextAvatarPositionWithPadding) max: \(maxAllowedPosition)")
        
        avatarOverlay.updateAvatar(
          for: primaryStickyRow,
          user: message.user ?? User.deletedInstance,
          yOffset: stickyPositionWhenPushed
        )
        
        avatarOverlay.updateAvatar(
          for: nextVisibleRow,
          user: messages[nextVisibleRow].user ?? User.deletedInstance,
          yOffset: nextAvatarPositionWithPadding
        )
        
        processedRows.insert(nextVisibleRow)
        processedRows.insert(primaryStickyRow)
      } else {
        // No avatar below to push against, use natural position
        avatarOverlay.updateAvatar(
          for: primaryStickyRow,
          user: message.user ?? User.deletedInstance,
          yOffset: stickyPosition
        )
        
        processedRows.insert(primaryStickyRow)
      }
    }
    
    // Update remaining visible avatars
    for row in visibleAvatarRows {
      if processedRows.contains(row) { continue }
      
      let message = messages[row]
      let yPosition = avatarNaturalPosition(at: row)
      
      avatarOverlay.updateAvatar(
        for: row,
        user: message.user ?? User.deletedInstance,
        yOffset: yPosition
      )
      processedRows.insert(row)
    }
    
    // Adding this dispatch makes double avatars show up sometimes
//    DispatchQueue.main.async {
    // Clean up non-visible avatars
    let currentAvatars = Set(avatarOverlay.avatarViews.keys)
    let avatarsToRemove = currentAvatars.subtracting(processedRows)
    avatarsToRemove.forEach { self.avatarOverlay.removeAvatar(for: $0) }
//    }
  }

  @objc func scrollViewFrameChanged(notification: Notification) {
    // Moved to did layout
//    if isAtBottom {
//      // Scroll to bottom
//      scrollToBottom(animated: false)
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
    
    let newWidth = tableView.bounds.width
//    let newWidth = width
    
    if lastKnownWidth == 0 {
      lastKnownWidth = newWidth
      recalculateVisibleHeightsWithCache()
//    } else if abs(newWidth - lastKnownWidth) > MessageSizeCalculator.widthChangeThreshold {
    } else if abs(newWidth - lastKnownWidth) > MessageSizeCalculator.widthChangeThreshold / 2 {
//    } else if abs(newWidth - lastKnownWidth) > 0.1 {
      // Handle height re-calc on width change
      lastKnownWidth = newWidth
      recalculateHeightsOnWidthChange()
    }
    
    log.trace("View did layout")
    log.trace("View at bottom \(isAtBottom)")
    log.trace("View needsInitialScroll \(needsInitialScroll)")

    // Important note:
    // If we stop doing initial scroll soon, it won't go all the way to the bottom initially
    if needsInitialScroll && !messages.isEmpty {
      scrollToBottom(animated: false)
      // Avatar would flash initially without this
      updateAvatars()
      // Don't stop initial scroll until initial width flactuation is done (hacky way to fix not going all the way to the bottom on initial render
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        // Very hacky way 😎
        self.needsInitialScroll = false
      }
    }
    
    // Note(@mo): This is a hack to fix scroll jumping when user is resizing the window at bottom.

    if isAtAbsoluteBottom {
      scrollToBottom(animated: false)
    }
  }

  func update(with newMessages: [FullMessage], width: CGFloat) {
    self.width = width
    guard !newMessages.isEmpty else { return }
    
    if messages.isEmpty {
      // Initial update
      messages = newMessages
      tableView.reloadData()
      
      view.layoutSubtreeIfNeeded()
      updateAvatars()
      return
    }

    performUpdate(with: newMessages, isInitialUpdate: messages.isEmpty || needsInitialScroll)
    updateAvatars()
  }
  
  private func performUpdate(with newMessages: [FullMessage], isInitialUpdate: Bool = false) {
    isPerformingUpdate = true
    let oldMessages = messages
    
    // Explicitly calculate insertions and removals
    let oldIds = Set(oldMessages.map { $0.id })
    let newIds = Set(newMessages.map { $0.id })
    
    let insertedIds = newIds.subtracting(oldIds)
    let removedIds = oldIds.subtracting(newIds)
    
    let insertions = newMessages.enumerated()
      .filter { insertedIds.contains($0.element.id) }
      .map { $0.offset }
    
    let removals = oldMessages.enumerated()
      .filter { removedIds.contains($0.element.id) }
      .map { $0.offset }
  
    let wasAtBottom = isAtBottom
    
    // Update data source first
    messages = newMessages

    if removals.isEmpty && insertions.isEmpty {
      // Find messages that have been updated by comparing old and new messages at same indexes
      let updatedIndexes: [Int] = messages.enumerated().compactMap { index, newMessage -> Int? in
        // Check if index is valid in old messages array
        guard index < oldMessages.count else { return nil }
        
        // Compare with message at same index
        let oldMessage = oldMessages[index]
        if oldMessage.message != newMessage.message {
          return index
        }
        return nil
      }
      
      // Reload only the rows that actually changed
      if !updatedIndexes.isEmpty {
        let indexSet = IndexSet(updatedIndexes)
        tableView.reloadData(
          forRowIndexes: indexSet,
          columnIndexes: IndexSet([0])
        )
      }
    }
//
    // Batch all visual updates
//    NSAnimationContext.runAnimationGroup { context in
    tableView.beginUpdates()

    if !removals.isEmpty {
      tableView.removeRows(at: IndexSet(removals), withAnimation: .effectFade)
    }
      
    if !insertions.isEmpty {
      tableView
        .insertRows(
          at: IndexSet(insertions),
          withAnimation: .effectFade
        )
    }
    tableView.endUpdates()
      
    if oldMessages.last != messages.last {
      // TODO: See if we can optimize here
      // last message changed height
      tableView.reloadData(forRowIndexes: IndexSet([messages.count - 2, messages.count - 1]), columnIndexes: IndexSet([0]))
      recalculateVisibleHeightsWithCache()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
      // Handle scroll position
      if (!removals.isEmpty || !insertions.isEmpty) && wasAtBottom {
        // Only animate if it's not the initial load
        //        self.scrollToBottom(animated: !isInitialUpdate)
        self.scrollToBottom(animated: true)
      }
    }
    
    isPerformingUpdate = false
      
//    } completionHandler: { [weak self] in
//      guard let self = self else { return }
//
//      isPerformingUpdate = false
//
//      // Verify the update
//      let actualRows = self.tableView.numberOfRows
//      let expectedRows = self.messages.count
//
//      if actualRows != expectedRows {
//        Log.shared.debug("⚠️ Row count mismatch - forcing reload")
//        self.tableView.reloadData()
//      }
//    }
  }
  
  private func getVisibleRowIndexes() -> IndexSet {
    // Guard against invalid state
    guard tableView.frame.height > 0,
          tableView.enclosingScrollView != nil,
          messages.count > 0
    else {
      return IndexSet()
    }
    
    let visibleRect = tableView.visibleRect
    // Guard against zero rect
    guard !visibleRect.isEmpty else {
      return IndexSet()
    }
    
    let visibleRange = tableView.rows(in: visibleRect)
    return IndexSet(integersIn: Int(visibleRange.location) ..< Int(visibleRange.location + visibleRange.length))
  }

  private func recalculateVisibleHeightsWithCache() {
    let visibleRect = tableView.visibleRect
    let visibleRange = tableView.rows(in: visibleRect)
    
    guard visibleRange.location != NSNotFound else { return }
    
    let bufferCount = 4
    
    // Calculate buffer ranges
    let startIndex = max(0, visibleRange.location - bufferCount)
    let endIndex = min(
      tableView.numberOfRows,
      visibleRange.location + visibleRange.length + bufferCount
    )
    
    let indexesToUpdate = IndexSet(
      integersIn: startIndex ..< endIndex
    )
    
    // disable animations
    
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // DO WE NEED THIS HERE???
    tableView.noteHeightOfRows(withIndexesChanged: indexesToUpdate)
    tableView
      .reloadData(forRowIndexes: indexesToUpdate, columnIndexes: IndexSet([0]))
    CATransaction.commit()
  }
  
  // Note this function will stop any animation that is happening so must be used with caution
  private func recalculateHeightsOnWidthChange() {
    log.trace("Recalculating heights on width change")
    let visibleRect = tableView.visibleRect
    let visibleRange = tableView.rows(in: visibleRect)
    
    guard visibleRange.location != NSNotFound else { return }
    
    let buffer = 0
  
    // Calculate ranges
    let visibleStartIndex = max(0, visibleRange.location - buffer)
    let visibleEndIndex = min(
      tableView.numberOfRows,
      visibleRange.location + visibleRange.length + buffer
    )
    
    // First, immediately update visible rows
    let visibleIndexesToUpdate = IndexSet(integersIn: visibleStartIndex ..< visibleEndIndex)
    
    // Begin updates
    
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    
    tableView.noteHeightOfRows(withIndexesChanged: visibleIndexesToUpdate)
    tableView.reloadData(forRowIndexes: visibleIndexesToUpdate, columnIndexes: IndexSet([0]))
    
    CATransaction.commit()
  }

  private func preserveScrollPosition(during update: (@escaping () -> Void) -> Void) {
    let scrollView = tableView.enclosingScrollView!
    let visibleRect = tableView.visibleRect
    
    // Find the first fully or partially visible row
    let firstVisibleRow = tableView.row(at: CGPoint(x: 0, y: visibleRect.minY))
    guard firstVisibleRow >= 0 else { return }
    
    // Calculate the offset from the top of the first visible row
    let rowRect = tableView.rect(ofRow: firstVisibleRow)
    let offsetFromRowTop = visibleRect.minY - rowRect.minY
    
    // Create restoration closure
    let restore = { [weak self] in
      guard let self else { return }
      
      // Get the new rect for the same row
      let newRowRect = self.tableView.rect(ofRow: firstVisibleRow)
      // Calculate the new scroll position
      let newY = newRowRect.minY + offsetFromRowTop
      
      // Apply the new scroll position
      scrollView.contentView.scroll(to: CGPoint(x: 0, y: newY))
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    
    // Perform the update with restoration callback
    update(restore)
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
    contentSizeObserver?.invalidate()
  }
}

extension MessagesTableView: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    messages.count
  }
}

extension MessagesTableView: NSTableViewDelegate {
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
    return row == 0
  }
  
//  func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
//    // Disable autoresizing mask constraints that might interfere with content layout
//    rowView.translatesAutoresizingMaskIntoConstraints = false
//  }
  
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard row >= 0, row < messages.count else { return nil }
      
    let message = messages[row]
    let identifier = NSUserInterfaceItemIdentifier("MessageCell")
      
    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? MessageTableCell
      ?? MessageTableCell()
    cell.identifier = identifier
    
    // get height
    var props = MessageViewProps(
      firstInGroup: isFirstInGroup(at: row),
      isLastMessage: isLastMessage(at: row),
      isFirstMessage: isFirstMessage(at: row),
      isRtl: message.message.text?.isRTL ?? false
    )

    let tableWidth = width
    // let tableWidth = tableView.bounds.width
    
    let size = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth)
    props.width = size.width
    props.height = size.height
    
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
      isRtl: message.message.text?.isRTL ?? false
    )
    
    let tableWidth = width
//    let tableWidth = tableView.bounds.width
    
    let size = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth)
    return size.height
  }
}
