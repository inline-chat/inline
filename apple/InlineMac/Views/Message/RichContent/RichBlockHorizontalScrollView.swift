import AppKit

/// A native horizontal viewport that leaves vertical message-list scrolling alone.
/// AppKit still owns natural direction, momentum, elasticity, and accessibility.
final class RichBlockHorizontalScrollView: NSScrollView {
  override func scrollWheel(with event: NSEvent) {
    guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
      nextResponder?.scrollWheel(with: event)
      return
    }
    super.scrollWheel(with: event)
  }
}
