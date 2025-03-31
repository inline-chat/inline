import AppKit

class MessageListScrollView: NSScrollView {
  override func flashScrollers() {
    // Do nothing to prevent flashing
  }
}

extension NSScrollView {
  func scrollWithoutFeedback(to point: NSPoint) {
    enclosingScrollView?.contentView.bounds.origin = point
  }

  /// Executes scrolling code with temporarily disabled scroll bars
  /// - Parameter action: The scrolling code to execute
  func withoutScrollerFlash(_ action: () -> Void) {
    // Store original states
//    let hadVerticalScroller = hasVerticalScroller
//    let hadHorizontalScroller = hasHorizontalScroller
    let hadVerticalScroller = true
    let hadHorizontalScroller = true

    // Temporarily disable scrollers
    hasVerticalScroller = false
    hasHorizontalScroller = false
    verticalScroller?.isHidden = true
    horizontalScroller?.isHidden = true

    // Execute the scrolling code
    action()

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // Restore original states
      hasVerticalScroller = hadVerticalScroller
      hasHorizontalScroller = hadHorizontalScroller
      verticalScroller?.isHidden = !hadVerticalScroller
      horizontalScroller?.isHidden = !hadHorizontalScroller
    }
  }
}

extension NSScrollView {
  func effectiveVisibleRect() -> CGRect {
    // Get the visible bounds in the scroll view's own coordinate space
    let visibleBounds = documentVisibleRect
    
    // Apply content insets to the visible rect
    let insetRect = NSRect(
      x: visibleBounds.origin.x,
      y: visibleBounds.origin.y + contentInsets.top,
      width: visibleBounds.width,
      height: visibleBounds.height - contentInsets.top - contentInsets.bottom
    )
    
    // The documentVisibleRect is already in the document view's coordinate space,
    // so we just need to apply the insets
    return insetRect
  }

}
