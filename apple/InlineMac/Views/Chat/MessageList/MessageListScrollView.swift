import AppKit

class MessageListScrollView: NSScrollView {
  override func flashScrollers() {
    // Do nothing to prevent flashing
  }
}

extension NSScrollView {
  /// Executes scrolling code with temporarily disabled scroll bars
  /// - Parameter action: The scrolling code to execute
  func withoutScrollerFlash(_ action: () -> Void) {
    // Store original states
    let hadVerticalScroller = hasVerticalScroller
    let hadHorizontalScroller = hasHorizontalScroller

    // Temporarily disable scrollers
    hasVerticalScroller = false
    hasHorizontalScroller = false
    verticalScroller?.isHidden = true
    horizontalScroller?.isHidden = true

    // Execute the scrolling code
    action()

    // Restore original states
    hasVerticalScroller = hadVerticalScroller
    hasHorizontalScroller = hadHorizontalScroller
    verticalScroller?.isHidden = !hadVerticalScroller
    horizontalScroller?.isHidden = !hadHorizontalScroller
  }
}
