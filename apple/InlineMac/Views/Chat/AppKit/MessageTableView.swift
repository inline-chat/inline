// MessagesViewController.swift
import AppKit
import InlineKit
import SwiftUI

class MessagesTableView: NSViewController {
  var width: CGFloat
  
  private var messages: [FullMessage] = []
  private var persistentViews: Set<NSTableCellView> = []

  private var scrollObserver: NSObjectProtocol?

  private var pendingMessages: [FullMessage] = []
  private let sizeCalculator = MessageSizeCalculator()

  private let defaultRowHeight = 44.0
  
  private let log = Log.scoped("MessagesTableView", enableTracing: true)
  
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
    
    let column = NSTableColumn(identifier: .init("messageColumn"))
    column.isEditable = false
    column.resizingMask = .autoresizingMask

    table.addTableColumn(column)
    
    // Enable automatic resizing
    table.autoresizingMask = [.height]
    table.delegate = self
    table.dataSource = self
  
//    table.wantsLayer = true
    //    table.layer?.backgroundColor = .clear
    // This helps with running listeners on every frame
//    table.layerContentsRedrawPolicy = .onSetNeedsDisplay
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
    scroll.drawsBackground = false // Add this line
    scroll.backgroundColor = .clear
//    scroll.wantsLayer = true
    // Used for quick scroll on resize
//    scroll.layerContentsRedrawPolicy = .onSetNeedsDisplay
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = tableView
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    
    scroll.verticalScrollElasticity = .allowed
    scroll.autohidesScrollers = true
    scroll.verticalScroller?.controlSize = .small // This makes it ultra-minimal

    scroll.postsBoundsChangedNotifications = true
    
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
    
    let lastRow = messages.count - 1
    
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
  }
  
  private var isAtBottom = true
  
  private var prevContentSize: CGSize = .zero
  private var isPerformingUpdate = false
  
  private func handleContentSizeChange(_ newHeight: CGFloat) {
    lastContentHeight = newHeight
    
    if isAtBottom && (!isPerformingUpdate || needsInitialScroll) {
      scrollToBottom(animated: false)
    }
  }
  
  @objc func scrollViewBoundsChanged(notification: Notification) {
    log.trace("scroll view bounds changed")
    
    if needsInitialScroll {
      // reports inaccurate heights at this point
      return
    }
    
    let scrollOffset = scrollView.contentView.bounds.origin
    let viewportSize = scrollView.contentView.bounds.size
    let contentSize = scrollView.documentView?.frame.size ?? .zero
    let maxScrollableHeight = contentSize.height + Theme.messageListBottomInset - viewportSize.height
    let currentScrollOffset = scrollOffset.y
    
    // Update scroll position
    let prevAtBottom = isAtBottom
    // Note(@mo): 38 is initial diff which will instantly make atBottom false and break scroll to bottom
    // when initial route is the chat and app is launched. This is a hack to prevent that.
    // but we need to find a way to keep this under 10.0 and instead fix the initial scroll to bottom.
    isAtBottom = abs(currentScrollOffset - maxScrollableHeight) <= 40.0
    
    if isAtBottom != prevAtBottom {
      log.trace("isAtBottom changed. isAtBottom = \(isAtBottom) currentScrollOffset = \(currentScrollOffset) maxScrollableHeight = \(maxScrollableHeight)")
    }
    
    // Update avatars as user scrolls
    updateAvatars()
    
    // Update heights that might have been changed if a width change happened in a different position
    // because we just update visible portion of the table
    recalculateHeightsOnWidthChange()
  }
  
  var avatarOverlay: AvatarOverlayView { avatarOverlayView }
  
  private func updateAvatars() {
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
      return row == 0 ?
        Theme.messageListTopInset + Theme.messageVerticalPadding :
        Theme.messageVerticalPadding
    }
    
    func availableViewportHeight() -> CGFloat {
      return scrollView.contentView.bounds.height - scrollTopInset
    }
    
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
        availableViewportHeight() - AvatarOverlayView.size - stickyPadding
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
          availableViewportHeight() - AvatarOverlayView.size - stickyPadding
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
    
    // Clean up non-visible avatars
    let currentAvatars = Set(avatarOverlay.avatarViews.keys)
    let avatarsToRemove = currentAvatars.subtracting(processedRows)
    avatarsToRemove.forEach { avatarOverlay.removeAvatar(for: $0) }
  }

  @objc func scrollViewFrameChanged(notification: Notification) {
    if isAtBottom {
      // Scroll to bottom
      scrollToBottom(animated: false)
    }
  }

  private var lastKnownWidth: CGFloat = 0
  private var needsInitialScroll = true
  
  override func viewDidLayout() {
    super.viewDidLayout()
    
    let newWidth = tableView.bounds.width
//    let newWidth = width
    
    var notWidthRelated = false
    if lastKnownWidth == 0 {
      lastKnownWidth = newWidth
      recalculateVisibleHeightsWithCache()
    } else if abs(newWidth - lastKnownWidth) > 0.1 {
      // Handle height re-calc on width change
      lastKnownWidth = newWidth
      recalculateHeightsOnWidthChange()
    } else {
      notWidthRelated = true
    }

    if needsInitialScroll && !messages.isEmpty {
      scrollToBottom(animated: false)
      // Avatar would flash initially without this
      updateAvatars()
      // Don't stop initial scroll until initial width flactuation is done (hacky way to fix not going all the way to the bottom on initial render
      if notWidthRelated {
        needsInitialScroll = false
      }
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
    NSAnimationContext.runAnimationGroup { _ in
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
        // last message changed height
        tableView.reloadData(forRowIndexes: IndexSet([messages.count - 2, messages.count - 1]), columnIndexes: IndexSet([0]))
        recalculateVisibleHeightsWithCache()
      }

      // Handle scroll position
      if (!removals.isEmpty || !insertions.isEmpty) && wasAtBottom && !isInitialUpdate {
//        DispatchQueue.main.async {
        self.scrollToBottom(animated: true)
//        }
      }
      
    } completionHandler: { [weak self] in
      guard let self = self else { return }
      
      isPerformingUpdate = false
      
      // Verify the update
      let actualRows = self.tableView.numberOfRows
      let expectedRows = self.messages.count
          
      if actualRows != expectedRows {
        Log.shared.debug("⚠️ Row count mismatch - forcing reload")
        self.tableView.reloadData()
      }
    }
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
  
  private func getNearestAvatarItemIndex() -> Int? {
    // Guard against invalid state
    guard tableView.frame.height > 0,
          tableView.enclosingScrollView != nil,
          messages.count > 0
    else {
      return nil
    }
    
    let topVisibleRect = tableView.visibleRect.divided(
      atDistance: 20,
      from: .minYEdge
    ).slice
    
    // Guard against zero rect
    guard !topVisibleRect.isEmpty else {
      return nil
    }
    
    let visibleRange = tableView.rows(in: topVisibleRect)
    let topLocation = visibleRange.location
    
    // find the first message that is first in group
    for i in (0...topLocation).reversed() {
      if isFirstInGroup(at: i) {
        return i
      }
    }
    return nil
  }
  
  private func getOffsetFromTopEdge(ofRow row: Int, currentOffset: CGFloat) -> CGFloat {
    guard row >= 0, row < messages.count else { return 0 }
    
    return tableView.rect(ofRow: row).minY - currentOffset
  }

  private func recalculateVisibleHeightsWithCache() {
    let visibleRect = tableView.visibleRect
    let visibleRange = tableView.rows(in: visibleRect)
    
    guard visibleRange.location != NSNotFound else { return }
    
    let bufferCount = 10
    
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
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      tableView.noteHeightOfRows(withIndexesChanged: indexesToUpdate)
    }
  }
  
  private var heightUpdateWorkItem: DispatchWorkItem?
  private let heightUpdateQueue = DispatchQueue(label: "com.app.heightUpdate", qos: .userInitiated)

  private func recalculateHeightsOnWidthChange() {
    // Cancel any pending updates
    heightUpdateWorkItem?.cancel()
    
    let visibleRect = tableView.visibleRect
    let visibleRange = tableView.rows(in: visibleRect)
    
    guard visibleRange.location != NSNotFound else { return }
    
    let bufferCount = 10
    
    // Calculate ranges
    let visibleStartIndex = max(0, visibleRange.location - bufferCount)
    let visibleEndIndex = min(
      tableView.numberOfRows,
      visibleRange.location + visibleRange.length + bufferCount
    )
    
    // First, immediately update visible rows
    let visibleIndexesToUpdate = IndexSet(integersIn: visibleStartIndex ..< visibleEndIndex)
    
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      self.tableView.noteHeightOfRows(withIndexesChanged: visibleIndexesToUpdate)
    }
  }

  private func recalculateAllHeights() {
    let indexesToUpdate = IndexSet(
      integersIn: 0 ..< tableView.numberOfRows
    )
      
    // disable animations
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      self.tableView.noteHeightOfRows(withIndexesChanged: indexesToUpdate)
    }
  }
  
//  private func preserveScrollPosition(during update: () -> Void) {
//    let scrollView = tableView.enclosingScrollView!
//    let visibleRect = tableView.visibleRect
//
//    // Store the first visible row and its offset
//    let firstVisibleRow = tableView.row(at: visibleRect.origin)
//    let offsetFromRow = visibleRect.origin.y - tableView.rect(ofRow: firstVisibleRow).origin.y
//
//    update()
//
//    // Restore scroll position
//    if firstVisibleRow >= 0 {
//      let newRowRect = tableView.rect(ofRow: firstVisibleRow)
//      let newOffset = CGPoint(x: 0, y: newRowRect.origin.y + offsetFromRow)
//      scrollView.contentView.scroll(newOffset)
//    }
//  }
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
      isFirstMessage: isFirstMessage(at: row)
    )
//    var props = MessageViewProps(firstInGroup: true)
    let tableWidth = width
//    let tableWidth = tableView.bounds.width
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
      isFirstMessage: isFirstMessage(at: row)
    )
    
    let tableWidth = width
//    let tableWidth = tableView.bounds.width
    let size = sizeCalculator.calculateSize(for: message, with: props, tableWidth: tableWidth)
    return size.height
  }
}
