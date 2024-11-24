// MessagesViewController.swift
import AppKit
import InlineKit
import SwiftUI

class MessagesTableView: NSViewController {
  private var messages: [FullMessage] = []

  private var scrollObserver: NSObjectProtocol?

  private var pendingMessages: [FullMessage] = []
  private let sizeCalculator = MessageSizeCalculator()
  private var sizeCache = NSCache<NSString, NSValue>()
  private let visibleRowsTracker = VisibleRowsTracker()

  private let defaultRowHeight = 44.0
  
  private lazy var tableView: NSTableView = {
    let table = NSTableView()
    table.backgroundColor = .clear
    table.headerView = nil
    table.rowSizeStyle = .custom
    table.selectionHighlightStyle = .none
    table.intercellSpacing = NSSize(width: 0, height: 0)
//    table.usesAutomaticRowHeights = false
    table.usesAutomaticRowHeights = false
    table.rowHeight = defaultRowHeight // Set an average expected height

//    table.wantsLayer = true
    let column = NSTableColumn(identifier: .init("messageColumn"))
    column.isEditable = false
    table.addTableColumn(column)
    
    // Important: Enable automatic resizing
    table.autoresizingMask = [.width, .height]

    table.delegate = self
    table.dataSource = self
    return table
  }()
  
  private lazy var scrollView: NSScrollView = {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.backgroundColor = .clear
    scroll.documentView = tableView
    scroll.wantsLayer = true
    // Used for quick scroll on resize
    scroll.layerContentsRedrawPolicy = .onSetNeedsDisplay
    scroll.translatesAutoresizingMaskIntoConstraints = false
    
    // Important: Set these properties
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
  
  private func handleContentSizeChange(_ newHeight: CGFloat) {
    lastContentHeight = newHeight
    
    if isAtBottom {
      scrollToBottom(animated: false)
    }
  }
  
  @objc func scrollViewBoundsChanged(notification: Notification) {
    let scrollOffset = scrollView.contentView.bounds.origin
    let viewportSize = scrollView.contentView.bounds.size
    let contentSize = scrollView.documentView?.frame.size ?? .zero
    let maxScrollableHeight = contentSize.height - viewportSize.height
    let currentScrollOffset = scrollOffset.y
    isAtBottom = abs(currentScrollOffset - maxScrollableHeight) <= 10.0
    
    recalculateVisibleHeightsWithCache()
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
    }
    if abs(newWidth - lastKnownWidth) > 1.0 {
      lastKnownWidth = newWidth
//      invalidateSizeCache()
      // Performance bottlneck, only reload indexes that their height changes
//      tableView.reloadData()
      recalculateVisibleHeightsWithCache()
    }
    
    if needsInitialScroll && !messages.isEmpty {
      scrollToBottom(animated: false)
      needsInitialScroll = false
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
    print("📝 Updating table - Current: \(messages.count), New: \(newMessages.count)")
    
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
    
    print("🔍 Found \(insertions.count) insertions at: \(insertions)")
    print("🔍 Found \(removals.count) removals at: \(removals)")
    
    let wasAtBottom = isAtBottom
    
    // Update data source first
    messages = newMessages
    
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
      
      // Handle scroll position
      if wasAtBottom && !isInitialUpdate {
        DispatchQueue.main.async {
          self.scrollToBottom(animated: true)
        }
      }
      
    } completionHandler: { [weak self] in
      guard let self = self else { return }
      
      // Verify the update
      let actualRows = self.tableView.numberOfRows
      let expectedRows = self.messages.count
          
      if actualRows != expectedRows {
        print("⚠️ Row count mismatch - forcing reload")
        self.tableView.reloadData()
      }
      
      // Force layout update
      // Probably unneccessary
      self.tableView.layout()
      self.tableView.needsDisplay = true
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

  private func invalidateSizeCache() {
    sizeCache.removeAllObjects()
  }
}

extension MessagesTableView: NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int {
    messages.count
  }
}

extension MessagesTableView: NSTableViewDelegate {
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard row >= 0, row < messages.count else { return nil }
      
    let message = messages[row]
    let identifier = NSUserInterfaceItemIdentifier("MessageCell")
      
    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? MessageTableCell
      ?? MessageTableCell()
    cell.identifier = identifier
    // TODO:
    cell.configure(with: message, props: MessageViewProps(firstInGroup: true))
    return cell
  }
    
  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    guard row >= 0, row < messages.count else {
      Log.shared.warning("Invalid row: \(row)")
      return defaultRowHeight
    }

    let message = messages[row]
    let width = tableView.bounds.width
    let cacheKey = "\(message.id):\(Int(width))" as NSString
    
    if let cachedSize = sizeCache.object(forKey: cacheKey)?.sizeValue {
      print("📏 Using cached size for row: \(row) width = \(cachedSize)")
      return cachedSize.height
    }
    
    // TODO:
    let props = MessageViewProps(
      firstInGroup: true
    )
      
    let availableWidth = tableView.bounds.width - 16
    let size = sizeCalculator.calculateSize(
      for: message,
      with: props,
      width: availableWidth
    )
      
    let finalSize = NSSize(width: availableWidth, height: size.height)
    sizeCache.setObject(NSValue(size: finalSize), forKey: cacheKey)
    print("📏 Calculated size for row: \(row) width = \(finalSize)")
    return finalSize.height
  }
}

// VisibleRowsTracker.swift
final class VisibleRowsTracker {
  private var visibleRows = IndexSet()
  private var preloadWindow: Int = 5
  
  func update(visibleIndexes: IndexSet, totalCount: Int) {
    let minRow = max(0, visibleIndexes.first ?? 0 - preloadWindow)
    let maxRow = min(totalCount - 1, visibleIndexes.last ?? 0 + preloadWindow)
    visibleRows = IndexSet(integersIn: minRow ... maxRow)
  }
  
  func shouldCalculateSize(for row: Int) -> Bool {
    visibleRows.contains(row)
  }
}
