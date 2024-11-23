//
//  ScrollManager.swift
//  Inline
//
//  Created by Mohammad Rajabifard on 11/22/24.
//
import AppKit
import Foundation
class ScrollManager {
  private weak var scrollView: NSScrollView?
  private weak var collectionView: NSCollectionView?
  private var isInitialScroll = true
  private var isPerformingScroll = false
  
  init(scrollView: NSScrollView, collectionView: NSCollectionView) {
    self.scrollView = scrollView
    self.collectionView = collectionView
    
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(scrollViewDidLayout),
      name: NSView.frameDidChangeNotification,
      object: scrollView
    )
    
    // Register for notification when collection view finishes layout
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(collectionViewLayoutDidFinish),
      name: NSCollectionView.frameDidChangeNotification,
      object: collectionView
    )
  }
  
  var needsInitialScroll = true
  
  @objc private func collectionViewLayoutDidFinish(_ notification: Notification) {
    guard needsInitialScroll else { return }
    needsInitialScroll = false
    
    // Ensure we're on main thread
    DispatchQueue.main.async { [weak self] in
      self?.scrollToBottom(animated: false)
    }
  }
  
  private func scrollToBottom(animated: Bool) {
//    guard let lastItemIndex = collectionView?.numberOfItems(inSection: 0),
//          lastItemIndex - 1 >= 0 else { return }
//    
//    let lastIndexPath = IndexPath(item: lastItemIndex  - 1, section: 0)
//    
//    // Force layout if needed
//    collectionView?.layoutSubtreeIfNeeded()
//    
//    // Disable animations
//    NSAnimationContext.runAnimationGroup { context in
//      context.duration = animated ? 0.3 : 0
//      context.allowsImplicitAnimation = animated
//      
//      // Scroll to bottom
//      collectionView?.scrollToItems(
//        at: [lastIndexPath],
//        scrollPosition: .bottom
//      )
//      
//      guard let scrollView = scrollView else { return }
//      // Force scroll view update
//      scrollView.reflectScrolledClipView(scrollView.contentView)
//    }
  }

  @objc private func scrollViewDidLayout(_ notification: Notification) {
    if isInitialScroll {
      scrollToBottom(animated: false)
      isInitialScroll = false
    }
  }
  
  func forceScrollToBottom() {
    guard let scrollView = scrollView,
          let documentView = scrollView.documentView else { return }
    
    // Disable animations
    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = 0
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    
    // Force layout
    documentView.layoutSubtreeIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
    
    let contentHeight = documentView.frame.height
    let clipViewHeight = scrollView.contentView.bounds.height
    
    if contentHeight > clipViewHeight {
      let maxScroll = contentHeight - clipViewHeight
      let targetPoint = NSPoint(x: 0, y: maxScroll)
      
      scrollView.contentView.setBoundsOrigin(targetPoint)
      scrollView.reflectScrolledClipView(scrollView.contentView)
      
      // Force display
      documentView.display()
      scrollView.display()
    }
    
    CATransaction.commit()
    NSAnimationContext.endGrouping()
  }
}
