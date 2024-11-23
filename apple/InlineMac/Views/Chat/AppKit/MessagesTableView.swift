// MessagesViewController.swift
import AppKit
import InlineKit
import SwiftUI

class MessagesTableView: NSViewController {
  private var messages: [FullMessage] = []
  private var pendingMessages: [FullMessage] = []
  private let sizeCalculator = MessageSizeCalculator()
  private var sizeCache = NSCache<NSString, NSValue>()
  
  private lazy var tableView: NSTableView = {
    let table = NSTableView()
    table.translatesAutoresizingMaskIntoConstraints = false
    table.backgroundColor = .clear
    table.headerView = nil
    table.rowSizeStyle = .custom
    table.selectionHighlightStyle = .none
    table.intercellSpacing = NSSize(width: 0, height: 1)
    
    let column = NSTableColumn(identifier: .init("messageColumn"))
    column.isEditable = false
    table.addTableColumn(column)
    
    table.delegate = self
    table.dataSource = self
    return table
  }()
  
  private lazy var scrollView: NSScrollView = {
    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.backgroundColor = .clear
    scroll.documentView = tableView
    return scroll
  }()
  
  override func loadView() {
    view = NSView()
    setupViews()
  }
  
  private func setupViews() {
    view.addSubview(scrollView)
    
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
  }
  
  private func scrollToBottom(animated: Bool) {
    guard messages.count > 0 else { return }
    
    let lastRow = messages.count - 1
    tableView.scrollRowToVisible(lastRow)
    
    if animated {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.3
        scrollView.reflectScrolledClipView(scrollView.contentView)
      }
    } else {
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
  }
  
  private var lastKnownWidth: CGFloat = 0
  private var needsInitialScroll = true
  
  override func viewDidLayout() {
    super.viewDidLayout()
    
    let newWidth = tableView.bounds.width
    if abs(newWidth - lastKnownWidth) > 1.0 {
      lastKnownWidth = newWidth
      invalidateSizeCache()
      tableView.reloadData()
    }
    
    if needsInitialScroll && !messages.isEmpty {
      scrollToBottom(animated: false)
      needsInitialScroll = false
    }
  }
  
  func update(with messages: [FullMessage]) {
    guard !messages.isEmpty else { return }
    
    pendingMessages = messages
    needsInitialScroll = true
    
    applyPendingUpdates()
  }
  
  private var isPerformingBatchUpdates = false
  private func applyPendingUpdates() {
    guard !isPerformingBatchUpdates else { return }
    
    let oldMessages = messages
    messages = pendingMessages
    
    let differences = pendingMessages.difference(from: oldMessages) { $0.id == $1.id }
    
    guard !differences.isEmpty else { return }
    
    isPerformingBatchUpdates = true
    tableView.beginUpdates()
    
    for change in differences {
      switch change {
      case .insert(let offset, _, _):
        tableView.insertRows(at: IndexSet(integer: offset), withAnimation: .effectFade)
      case .remove(let offset, _, _):
        tableView.removeRows(at: IndexSet(integer: offset), withAnimation: .effectFade)
      }
    }
    
    tableView.endUpdates()
    isPerformingBatchUpdates = false
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
    cell.configure(with: message, showsSender: true)
    return cell
  }
    
  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    guard row >= 0, row < messages.count else { return 44 } // Default height if invalid row
      
    let message = messages[row]
    let cacheKey = "\(message.id):\(tableView.bounds.width)" as NSString
      
    if let cachedSize = sizeCache.object(forKey: cacheKey)?.sizeValue {
      return cachedSize.height
    }
      
    let availableWidth = tableView.bounds.width - 16
    let size = sizeCalculator.calculateSize(
      for: message.message.text ?? " ",
      width: availableWidth
    )
      
    let finalSize = NSSize(width: availableWidth, height: size.height + 16)
    sizeCache.setObject(NSValue(size: finalSize), forKey: cacheKey)
    return finalSize.height
  }
}

class MessageTableCell: NSTableCellView {
  private var messageView: MessageViewAppKit?
  
  override init(frame: NSRect) {
    super.init(frame: frame)
    setupView()
  }
  
  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupView()
  }
  
  private func setupView() {
    wantsLayer = true
    layer?.backgroundColor = .clear
  }
  
  func configure(with fullMessage: FullMessage, showsSender: Bool) {
    messageView?.removeFromSuperview()
    
    let newMessageView = MessageViewAppKit(fullMessage: fullMessage, showsSender: showsSender)
    newMessageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(newMessageView)
    
    NSLayoutConstraint.activate([
      newMessageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      newMessageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      newMessageView.topAnchor.constraint(equalTo: topAnchor),
      newMessageView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
    
    messageView = newMessageView
  }
}
