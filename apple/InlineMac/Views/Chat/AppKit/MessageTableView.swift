// MessagesViewController.swift
import AppKit
import InlineKit
import SwiftUI

class MessagesTableView: NSViewController {
  var width: CGFloat
  
  private var messages: [FullMessage] = []

  private var scrollObserver: NSObjectProtocol?

  private var pendingMessages: [FullMessage] = []
  private let sizeCalculator = MessageSizeCalculator()
//  private var sizeCache = NSCache<NSString, NSValue>()

  private let defaultRowHeight = 44.0
  
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
    // Add content insets
  
//    table.usesAutomaticRowHeights = true
    table.usesAutomaticRowHeights = false
    table.rowHeight = defaultRowHeight
    table.layer?.backgroundColor = .clear
    
    let column = NSTableColumn(identifier: .init("messageColumn"))
    column.isEditable = false
    column.resizingMask = .autoresizingMask

    table.addTableColumn(column)
    
    // Important: Enable automatic resizing
    table.autoresizingMask = [.height]
//    table.autoresizingMask = [.width, .height]
    table.delegate = self
    table.dataSource = self
    
//    table.backgroundColor = .init(red: 0, green: 0, blue: 0, alpha: 0.3)

    // too expenstive on inital render
//    table.style = .fullWidth
  
    table.wantsLayer = true
    // Use layer-backing for better performance
    table.layerContentsRedrawPolicy = .onSetNeedsDisplay
    return table
  }()

  private lazy var scrollView: NSScrollView = {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = false // Add this line
    scroll.backgroundColor = .clear
    scroll.wantsLayer = true
    // Used for quick scroll on resize
    scroll.layerContentsRedrawPolicy = .onSetNeedsDisplay
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = tableView

    // Add bottom spacing
//    scroll.automaticallyAdjustsContentInsets = false
//    scroll.contentInsets = NSEdgeInsets(
//      top: 0,
//      left: 0,
//      bottom: Theme.messageListBottomInset,
//      right: 0
//    )
//    scroll.scrollerInsets = NSEdgeInsets(
//      top: 0,
//      left: 0,
//      bottom: -Theme.messageListBottomInset,
//      right: 0
//    )
    
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    scroll.verticalScrollElasticity = .allowed
    scroll.autohidesScrollers = true

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
    print("scroll to bottom")
    
    let lastRow = messages.count - 1
    
    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.25
        context.allowsImplicitAnimation = true
        tableView.scrollRowToVisible(lastRow)
      }
    } else {
      tableView.scrollRowToVisible(lastRow)
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
      if abs(newHeight - lastContentHeight) > 0.5 {
        handleContentSizeChange(newHeight)
      }
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
    if needsInitialScroll {
      // reports inaccurate heights at this point
      return
    }
    
    let scrollOffset = scrollView.contentView.bounds.origin
    let viewportSize = scrollView.contentView.bounds.size
    let contentSize = scrollView.documentView?.frame.size ?? .zero
    let maxScrollableHeight = contentSize.height + Theme.messageListBottomInset - viewportSize.height
    let currentScrollOffset = scrollOffset.y
    print("🔍 Scroll offset: \(currentScrollOffset), max: \(maxScrollableHeight)")
    isAtBottom = abs(currentScrollOffset - maxScrollableHeight) <= 10.0
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
    if lastKnownWidth == 0 {
      lastKnownWidth = newWidth
      recalculateVisibleHeightsWithCache()
    }
    if abs(newWidth - lastKnownWidth) > 0.1 {
      lastKnownWidth = newWidth
//      invalidateSizeCache()
      // Performance bottlneck, only reload indexes that their height changes
      tableView.reloadData()
//      recalculateVisibleHeightsWithCache()
//      sizeCalculator.invalidateCache()
//      recalculateAllHeights()
//      tableView.layout()
    }
    
    if needsInitialScroll && !messages.isEmpty {
      scrollToBottom(animated: false)
      needsInitialScroll = false
    }
  }

  func update(with newMessages: [FullMessage], width: CGFloat) {
    self.width = width
    guard !newMessages.isEmpty else { return }
    
    if messages.isEmpty {
      // Initial update
      messages = newMessages
      tableView.reloadData()
      // Force immediate layout
      view.layoutSubtreeIfNeeded()
      return
    }

    performUpdate(with: newMessages, isInitialUpdate: messages.isEmpty || needsInitialScroll)
  }
  
  private func performUpdate(with newMessages: [FullMessage], isInitialUpdate: Bool = false) {
    print("📝 Updating table - Current: \(messages.count), New: \(newMessages.count)")
    
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
    
//    print("wasAtBottom \(isAtBottom)")
    
    // Update data source first
    messages = newMessages
//
    
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
      
      print("🔍 Found \(updatedIndexes.count) updated messages at: \(updatedIndexes)")
      
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
        DispatchQueue.main.async {
          self.scrollToBottom(animated: true)
        }
      }
      
    } completionHandler: { [weak self] in
      guard let self = self else { return }
      
      isPerformingUpdate = false
      
      // Verify the update
      let actualRows = self.tableView.numberOfRows
      let expectedRows = self.messages.count
          
      if actualRows != expectedRows {
        print("⚠️ Row count mismatch - forcing reload")
        self.tableView.reloadData()
      }
      
      // Force layout update
      // Probably unneccessary
//      self.tableView.layout()
//      self.tableView.needsDisplay = true
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
