// MessagesViewController.swift
import AppKit
import InlineKit
import SwiftUI

class MessagesViewController: NSViewController {
  private var messages: [FullMessage] = []
  private var pendingMessages: [FullMessage] = []
  private let sizeCalculator = MessageSizeCalculator()
  private var sizeCache = NSCache<NSString, NSValue>()

  private lazy var collectionView: NSCollectionView = {
    let view = NSCollectionView()
    // Configure NSCollectionView
    view.translatesAutoresizingMaskIntoConstraints = false
    view.collectionViewLayout = createLayout()
    view.isSelectable = false
    view.allowsMultipleSelection = false
    view.prefetchDataSource = self
    view.register(MessageCell.self, forItemWithIdentifier: .init(MessageCell.reuseIdentifier))
    view.dataSource = self
    view.delegate = self
    return view
  }()

  private lazy var scrollView: NSScrollView = {
    let scroll = NSScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.backgroundColor = .clear
    scroll.documentView = collectionView
    return scroll
  }()

  override func loadView() {
    view = NSView()
    setupViews()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
  }

  private func scrollToBottom(animated: Bool) {
    let lastItemIndex = collectionView.numberOfItems(inSection: 0)
    if lastItemIndex - 1 >= 0 {} else { return }

    let lastIndexPath = IndexPath(item: lastItemIndex - 1, section: 0)

    // Force layout if needed
    collectionView.layoutSubtreeIfNeeded()

    // Disable animations
    NSAnimationContext.runAnimationGroup { context in
      context.duration = animated ? 0.3 : 0
      context.allowsImplicitAnimation = animated

      // Scroll to bottom
      collectionView.scrollToItems(
        at: [lastIndexPath],
        scrollPosition: .bottom
      )

      // Force scroll view update
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
  }

  private func setupViews() {
    view.addSubview(scrollView)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func createLayout() -> NSCollectionViewFlowLayout {
    let layout = MessagesCollectionViewLayout()
    layout.scrollDirection = .vertical
    layout.minimumInteritemSpacing = 0
    layout.minimumLineSpacing = 1
    layout.sectionInset = .init(top: 0, left: 0, bottom: 0, right: 0)
    // Remove estimated item size - we'll handle this differently
    return layout
  }

  private var lastKnownWidth: CGFloat = 0
  private var needsInitialScroll = true

//  override func viewWillLayout() {
//    super.viewWillLayout()
//    
//    if isInitialLayout && !messages.isEmpty {
//      // Calculate total content height
//      var totalHeight: CGFloat = 0
//      for index in 0..<messages.count {
//        let indexPath = IndexPath(item: index, section: 0)
//        if let attributes = collectionView.collectionViewLayout?.layoutAttributesForItem(at: indexPath) {
//          totalHeight += attributes.frame.height
//        }
//      }
//      
//      // Set initial content offset
//      let maxOffset = max(0, totalHeight - collectionView.bounds.height)
//      scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxOffset))
//      scrollView.reflectScrolledClipView(scrollView.contentView)
//    }
//  }

  override func viewDidLayout() {
    super.viewDidLayout()

    let newWidth = collectionView.bounds.width
    if abs(newWidth - lastKnownWidth) > 1.0 {
      lastKnownWidth = newWidth
      invalidateSizeCache()
      collectionView.collectionViewLayout?.invalidateLayout()
    }
    
    //
  
    // Handle initial scroll
    if needsInitialScroll && !messages.isEmpty {
      // Ensure we have valid layout metrics
      collectionView.layoutSubtreeIfNeeded()
      
      if collectionView.collectionViewLayout?.layoutAttributesForElements(in: collectionView.bounds) != nil {
        let lastItemIndex = collectionView.numberOfItems(inSection: 0) - 1
        if lastItemIndex >= 0 {
          let lastIndexPath = IndexPath(item: lastItemIndex, section: 0)
          
          // Disable animations
          NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            
            collectionView.scrollToItems(at: [lastIndexPath], scrollPosition: .bottom)
            scrollView.reflectScrolledClipView(scrollView.contentView)
          }
        }
        
        needsInitialScroll = false
      }
    }

  }

  func update(with messages: [FullMessage]) {
    guard !messages.isEmpty else { return }

    pendingMessages = messages
    
    needsInitialScroll = true  // Reset the flag when new messages arrive

    
    applyPendingUpdates()
  }

  private var isFirstRender = true
  private var isPerformingBatchUpdates = false
  private func applyPendingUpdates() {
    guard !isPerformingBatchUpdates else { return }

    let oldMessages = messages
    messages = pendingMessages

    let differences = pendingMessages.difference(from: oldMessages) { $0.id == $1.id }

    guard !differences.isEmpty else { return }

    isPerformingBatchUpdates = true

    collectionView.performBatchUpdates({ [weak self] in
      guard let self = self else { return }

      for change in differences {
        switch change {
        case .insert(let offset, _, _):
          collectionView.insertItems(at: [IndexPath(item: offset, section: 0)])
        case .remove(let offset, _, _):
          collectionView.deleteItems(at: [IndexPath(item: offset, section: 0)])
        }
      }

    }) { [weak self] finished in
      guard let self = self, finished else { return }

      self.isPerformingBatchUpdates = false
    }
  }

  private func invalidateSizeCache() {
    sizeCache.removeAllObjects()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}

extension MessagesViewController: NSCollectionViewDataSource {
  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int)
    -> Int
  {
    messages.count
  }

  func collectionView(
    _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
  ) -> NSCollectionViewItem {
    let item = collectionView.makeItem(
      withIdentifier: .init(MessageCell.reuseIdentifier), for: indexPath
    )
    guard let cell = item as? MessageCell else { return item }
    cell.configure(with: messages[indexPath.item], showsSender: true)
    return cell
  }
}

// Optimize the delegate methods
extension MessagesViewController: NSCollectionViewDelegateFlowLayout {
  func collectionView(
    _ collectionView: NSCollectionView,
    layout collectionViewLayout: NSCollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> NSSize {
    let message = messages[indexPath.item]
    let cacheKey = "\(message.id):\(collectionView.bounds.width)" as NSString

    if let cachedSize = sizeCache.object(forKey: cacheKey)?.sizeValue {
      return cachedSize
    }

    let availableWidth = collectionView.bounds.width - 16
    let size = sizeCalculator.calculateSize(
      for: message.message.text ?? " ",
      width: availableWidth
    )

    let finalSize = NSSize(width: availableWidth, height: size.height + 16)
    sizeCache.setObject(NSValue(size: finalSize), forKey: cacheKey)
    return finalSize
  }

  func collectionView(
    _ collectionView: NSCollectionView,
    layout collectionViewLayout: NSCollectionViewLayout,
    referenceSizeForHeaderInSection section: Int
  ) -> NSSize {
    .zero
  }

  func collectionView(
    _ collectionView: NSCollectionView,
    layout collectionViewLayout: NSCollectionViewLayout,
    referenceSizeForFooterInSection section: Int
  ) -> NSSize {
    .zero
  }
}

class MessagesCollectionViewLayout: NSCollectionViewFlowLayout {
  private var lastKnownWidth: CGFloat = 0
  private var layoutInfo: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
  private var isInitialLayout = true

  override func prepare() {
    super.prepare()
    guard let collectionView = collectionView else { return }

    layoutInfo.removeAll()

    let width = collectionView.bounds.width
    lastKnownWidth = width
    
    // Ensure initial layout is complete
    if isInitialLayout {
      collectionView.layoutSubtreeIfNeeded()
      isInitialLayout = false
    }

  }

  override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
    return abs(newBounds.width - lastKnownWidth) > 1
  }

  override func invalidationContext(forBoundsChange newBounds: NSRect) -> NSCollectionViewLayoutInvalidationContext {
    let context = super.invalidationContext(forBoundsChange: newBounds)
    guard let flowContext = context as? NSCollectionViewFlowLayoutInvalidationContext else {
      return context
    }
    flowContext.invalidateFlowLayoutDelegateMetrics = false
    return context
  }
}

extension MessagesViewController: NSCollectionViewPrefetching {
  func collectionView(
    _ collectionView: NSCollectionView,
    prefetchItemsAt indexPaths: [IndexPath]
  ) {
    // Preload content for upcoming cells
    for indexPath in indexPaths {
      let message = messages[indexPath.item]
      _ = sizeCalculator.calculateSize(for: message.message.text ?? "", width: collectionView.bounds.width)
    }
  }
}
