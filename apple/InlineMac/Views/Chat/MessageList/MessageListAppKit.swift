// MessagesViewController.swift
import AppKit
import InlineKit
import SwiftUI

class MessageListAppKit: NSViewController {
  private let log = Log.scoped("MessageListAppKit", enableTracing: true)
  private var messages: [FullMessage] = []
  private let sizeCalculator = MessageSizeCalculator()
  private let defaultRowHeight = 24.0
  
  // Specification - mostly useful in debug
  private var feature_maintainsScrollFromBottomOnResize = true
  private var feature_scrollsToBottomOnNewMessage = true
  private var feature_scrollsToBottomInDidLayout = true
  private var feature_setupsInsetsManually = true
  private var feature_updatesHeightsOnWidthChange = true
  private var feature_updatesHeightsOnOffsetChange = true
  
  init() {
    super.init(nibName: nil, bundle: nil)
  }
  
  required init?(coder: NSCoder) {
    super.init(coder: coder)
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
    
    // Experimental
//    table.wantsLayer = true
//    table.layerContentsRedrawPolicy = .onSetNeedsDisplay
    
    let column = NSTableColumn(identifier: .init("messageColumn"))
    column.isEditable = false
    column.resizingMask = .autoresizingMask
    // Important: Set these properties
    
    table.addTableColumn(column)
    
    // Enable automatic resizing
    table.autoresizingMask = [.height]
//    table.autoresizingMask = []
    table.delegate = self
    table.dataSource = self
  
    return table
  }()
  
//  private lazy var avatarOverlayView: AvatarOverlayView = {
//    let manager = AvatarOverlayView(frame: .zero)
//    manager.translatesAutoresizingMaskIntoConstraints = false
//    return manager
//  }()
  
  private lazy var scrollView: NSScrollView = {
    let scroll = MessageListScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = false // Add this line
    scroll.backgroundColor = .clear
    // Used for quick scroll on resize
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

  // This fixes the issue with the toolbar messing up initial content insets on window open. Now we call it on did layout and it fixes the issue.
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
        bottom: Theme.messageListBottomInset,
        right: 0
      )
      scrollView.scrollerInsets = NSEdgeInsets(
        top: 0,
        left: 0,
        bottom: -Theme.messageListBottomInset, // Offset it to touch bottom
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
//    view.addSubview(avatarOverlayView)
    
    // Set up constraints
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      
//      avatarOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
//      avatarOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.messageSidePadding),
//      avatarOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
//      avatarOverlayView.widthAnchor.constraint(
//        equalToConstant: AvatarOverlayView.size + Theme.messageSidePadding
//      )
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
        
        tableView.scrollToBottomWithInset()
//        tableView.scrollRowToVisible(lastRow)
      }
    } else {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      tableView.scrollToBottomWithInset()
//      tableView.scrollRowToVisible(lastRow)
      CATransaction.commit()
    }
  }

  private func setupScrollObserver() {
    // Use direct observation for immediate response
    scrollView.contentView.postsFrameChangedNotifications = true
    scrollView.contentView.postsBoundsChangedNotifications = true
    
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
  
  private var prevOffset: CGFloat = 0
  
  @objc func scrollViewBoundsChanged(notification: Notification) {
    log.trace("scroll view bounds changed")
    
    // Update avatars as user scrolls
    //    updateAvatars()
    
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
    
    if feature_updatesHeightsOnOffsetChange && isUserScrolling {
      recalculateHeightsOnWidthChange()
    }
  }

  // Using CFAbsoluteTimeGetCurrent()
  private func measureTime(_ closure: () -> Void, name: String = "Function") {
    let start = CFAbsoluteTimeGetCurrent()
    closure()
    let end = CFAbsoluteTimeGetCurrent()
    let timeElapsed = (end - start) * 1000 // Convert to milliseconds
    log.trace("\(name) took \(String(format: "%.2f", timeElapsed))ms")
  }
  
//  private func _updateAvatars() {
//    log.trace("update avatars")
//    let stickyPadding: CGFloat = 8.0
//    let scrollTopInset = scrollView.contentInsets.top
//    let viewportHeight = scrollView.contentView.bounds.height
//    let currentOffset = scrollView.contentView.bounds.origin.y
//    let visibleRect = tableView.visibleRect
//    let visibleRectMinusTopInset = visibleRect.offsetBy(dx: 0, dy: scrollTopInset)
//    log.trace("Visible rect: \(visibleRect)")
//    log.trace("Visible rect minus top inset: \(visibleRectMinusTopInset)")
//    let visibleRange = tableView.rows(in: visibleRectMinusTopInset)
//    guard visibleRange.location != NSNotFound else { return }
//    guard visibleRange.length > 0 else { return }
//
//    var processedRows = Set<Int>()
//
//    // utils
//    func avatarPadding(at row: Int) -> CGFloat {
//      let padding = row == 0 ?
//        Theme.messageListTopInset + Theme.messageVerticalPadding :
//        Theme.messageVerticalPadding
//
//      return padding + Theme.messageGroupSpacing
//    }
//
//    let availableViewportHeight = scrollView.contentView.bounds.height - scrollTopInset
//
//    func avatarNaturalPosition(at row: Int) -> CGFloat {
//      return viewportHeight - (tableView.rect(ofRow: row).minY - currentOffset) - AvatarOverlayView.size - avatarPadding(at: row)
//    }
//
//    // Find sticky avatars
//    var stickyRow: Int? = nil
//    var upcomingSticky: Int? = nil
//
//    // sticky out of bound
//    for row in (0...Int(visibleRange.location)).reversed() {
//      if isFirstInGroup(at: row) {
//        stickyRow = row
//        break
//      }
//    }
//
//    // top most avatar below sticky
//    for row in Int(visibleRange.location) ..< Int(visibleRange.location + visibleRange.length) {
//      // skip current sticky
//      if isFirstInGroup(at: row) && row != stickyRow {
//        upcomingSticky = row
//        break
//      }
//    }
//
//    // Get visible avatar rows
//    let visibleAvatarRows = (Int(visibleRange.location)...Int(visibleRange.location + visibleRange.length))
//      .filter { row in
//        row < messages.count && isFirstInGroup(at: row)
//      }
//
//    // Handle sticky avatar
//    if let primaryStickyRow = stickyRow {
//      let message = messages[primaryStickyRow]
//
//      // Calculate the natural position where avatar would be without any constraints
//      let naturalPosition = avatarNaturalPosition(at: primaryStickyRow)
//
//      // Min it with the viewport height - avatar size - padding so it doesn't go out of bounds of screen
//      let stickyPosition = min(
//        naturalPosition,
//        availableViewportHeight - AvatarOverlayView.size - stickyPadding
//      )
//
//      // Find the first visible avatar below the sticky one, we need it so it pushes the sticky avatar up as it's about to overlap
//      if let nextVisibleRow = upcomingSticky,
//         // when fully overlap, ignore
//         nextVisibleRow != primaryStickyRow
//      {
//        let nextAvatarPosition = avatarNaturalPosition(at: nextVisibleRow)
//        // so it doesn't go above sticky padding immediately before becoming sticky and causing jump
//        let nextAvatarPositionWithPadding = min(
//          nextAvatarPosition,
//          availableViewportHeight - AvatarOverlayView.size - stickyPadding
//        )
//
//        // Calculate the maximum allowed position (just above the next avatar)
//        let maxAllowedPosition = nextAvatarPosition + AvatarOverlayView.size + stickyPadding
//
//        // Use the higher position (more towards top of screen) between natural and pushed
//        let stickyPositionWhenPushed = max(stickyPosition, maxAllowedPosition)
//
//        log.trace("Sticky position: \(stickyPosition), pushed: \(stickyPositionWhenPushed), next: \(nextAvatarPosition), nextWithPadding: \(nextAvatarPositionWithPadding) max: \(maxAllowedPosition)")
//
//        avatarOverlay.updateAvatar(
//          for: primaryStickyRow,
//          user: message.user ?? User.deletedInstance,
//          yOffset: stickyPositionWhenPushed
//        )
//
//        avatarOverlay.updateAvatar(
//          for: nextVisibleRow,
//          user: messages[nextVisibleRow].user ?? User.deletedInstance,
//          yOffset: nextAvatarPositionWithPadding
//        )
//
//        processedRows.insert(nextVisibleRow)
//        processedRows.insert(primaryStickyRow)
//      } else {
//        // No avatar below to push against, use natural position
//        avatarOverlay.updateAvatar(
//          for: primaryStickyRow,
//          user: message.user ?? User.deletedInstance,
//          yOffset: stickyPosition
//        )
//
//        processedRows.insert(primaryStickyRow)
//      }
//    }
//
//    // Update remaining visible avatars
//    for row in visibleAvatarRows {
//      if processedRows.contains(row) { continue }
//
//      let message = messages[row]
//      let yPosition = avatarNaturalPosition(at: row)
//
//      avatarOverlay.updateAvatar(
//        for: row,
//        user: message.user ?? User.deletedInstance,
//        yOffset: yPosition
//      )
//      processedRows.insert(row)
//    }
//
//    // Adding this dispatch makes double avatars show up sometimes
  ////    DispatchQueue.main.async {
//    // Clean up non-visible avatars
//    let currentAvatars = Set(avatarOverlay.avatarViews.keys)
//    let avatarsToRemove = currentAvatars.subtracting(processedRows)
//    avatarsToRemove.forEach { self.avatarOverlay.removeAvatar(for: $0) }
  ////    }
//  }

  var oldScrollViewHeight: CGFloat = 0.0
  var oldDistanceFromBottom: CGFloat = 0.0
  
  @objc func scrollViewFrameChanged(notification: Notification) {
    // keep scroll view anchored from the bottom
    guard feature_maintainsScrollFromBottomOnResize else { return }
    
    guard let documentView = scrollView.documentView else { return }
    
    if isPerformingUpdate {
      // Do not maintain scroll when performing update, TODO: Fix later
      return
    }
  
    let scrollOffset = scrollView.contentView.bounds.origin
    let viewportSize = scrollView.contentView.bounds.size
    let contentSize = scrollView.documentView?.frame.size ?? .zero
    let maxScrollableHeight = contentSize.height - viewportSize.height
    let currentScrollOffset = scrollOffset.y
    
    // TODO: min max
    let nextScrollPosition = contentSize.height - (oldDistanceFromBottom + viewportSize.height)
    
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // Set new scroll position
    documentView.scroll(NSPoint(x: 0, y: nextScrollPosition))
    CATransaction.commit()
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
      scrollToBottom(animated: false)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.needsInitialScroll = false
      }
    }
    
    if feature_scrollsToBottomInDidLayout {
      // Note(@mo): This is a hack to fix scroll jumping when user is resizing the window at bottom.
      if isAtAbsoluteBottom {
        scrollToBottom(animated: false)
      }
    }
  }
  
  // Called on did layout
  func checkWidthChangeForHeights() {
    guard feature_updatesHeightsOnWidthChange else { return }
    
    let newWidth = tableView.bounds.width
    
    if abs(newWidth - lastKnownWidth) > MessageSizeCalculator.safeAreaWidth {
      lastKnownWidth = newWidth
      recalculateHeightsOnWidthChange()
    }
  }

  func update(with newMessages: [FullMessage]) {
    guard !newMessages.isEmpty else { return }
    
    if messages.isEmpty {
      // Initial update
      messages = newMessages
      tableView.reloadData()
      return
    }

    performUpdate(with: newMessages, isInitialUpdate: messages.isEmpty || needsInitialScroll)
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

    NSAnimationContext.runAnimationGroup { _ in
      
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
    }

    // TODO: instead of this, mark next update scroll is animated
    if feature_scrollsToBottomOnNewMessage {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
        // Handle scroll position
        if (!removals.isEmpty || !insertions.isEmpty) && wasAtBottom {
          self.scrollToBottom(animated: true)
        }
      }
    }
    
    isPerformingUpdate = false
  }
  
  // Note this function will stop any animation that is happening so must be used with caution
  private func recalculateHeightsOnWidthChange() {
    log.trace("Recalculating heights on width change")
    let visibleRect = tableView.visibleRect
    let visibleRange = tableView.rows(in: visibleRect)
    
    if isPerformingUpdate {
      log.trace("Ignoring recalculation due to ongoing update")
      return
    }
    
    guard visibleRange.location != NSNotFound else { return }
    
    let buffer = 4

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
    
    // Begin updates
    
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    // Reload top most view
//    tableView
//      .reloadData(
//        forRowIndexes: IndexSet(integer: visibleRange.location),
//        columnIndexes: IndexSet([0])
//      )
    tableView
      .reloadData(
        forRowIndexes: visibleIndexesToUpdate,
        columnIndexes: IndexSet([0])
      )
    tableView.noteHeightOfRows(withIndexesChanged: visibleIndexesToUpdate)
    
    CATransaction.commit()
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
    
    var props = MessageViewProps(
      firstInGroup: isFirstInGroup(at: row),
      isLastMessage: isLastMessage(at: row),
      isFirstMessage: isFirstMessage(at: row),
      isRtl: message.message.text?.isRTL ?? false
    )

    let tableWidth = tableView.bounds.width
    let (_, textSize) = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth)

    props.textWidth = textSize.width
    props.textHeight = textSize.height
  
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
    
    let tableWidth = tableView.bounds.width
    
    let (size, _) = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth)
    return size.height
  }
}

extension NSTableView {
  func scrollToBottomWithInset() {
    guard let scrollView = enclosingScrollView,
          numberOfRows > 0 else { return }
    
    let lastRow = numberOfRows - 1
    let lastRowRect = rect(ofRow: lastRow)
    
    // Get the bottom inset value
    let bottomInset = scrollView.contentInsets.bottom
    
    // Calculate the point that includes the bottom inset
    let maxVisibleY = scrollView.documentView?.bounds.maxY ?? 0
    let targetPoint = NSPoint(
      x: 0,
      y: maxVisibleY + bottomInset - scrollView.contentView.bounds.height
    )
    
    scrollView.contentView.scroll(targetPoint)
    
    // Ensure the last row is visible
    scrollRowToVisible(lastRow)
  }
}
