import AppKit

/// Shared horizontal geometry for the conversation and its composer.
enum ChatLayoutMetrics {
  static let maximumWidth: CGFloat = 750
  static let leadingControlCenterX: CGFloat = 32

  static func avatarLeadingInset(size: CGFloat) -> CGFloat {
    leadingControlCenterX - size / 2
  }
}

class MessageListScrollView: NSScrollView {
  static let centeredChatWidth = ChatLayoutMetrics.maximumWidth
  let messageColumnGuide = NSLayoutGuide()
  private var columnWidth: NSLayoutConstraint?

  var messageContentWidth: CGFloat {
    min(contentSize.width, maximumContentWidth ?? contentSize.width)
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    contentView = CenteredMessageClipView()
    addLayoutGuide(messageColumnGuide)
    columnWidth = messageColumnGuide.widthAnchor.constraint(equalToConstant: messageContentWidth)
    NSLayoutConstraint.activate([
      messageColumnGuide.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      messageColumnGuide.topAnchor.constraint(equalTo: contentView.topAnchor),
      messageColumnGuide.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      columnWidth!,
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var maximumContentWidth: CGFloat? {
    didSet {
      guard maximumContentWidth != oldValue else { return }
      (contentView as? CenteredMessageClipView)?.maximumDocumentWidth = maximumContentWidth
      tile()
    }
  }

  override func tile() {
    super.tile()
    columnWidth?.constant = messageContentWidth
    (contentView as? CenteredMessageClipView)?.recenterDocument()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    MessageGestureTrace.trace("MessageListScrollView.hitTest parentPoint=\(MessageGestureTrace.point(point)) hit=\(MessageGestureTrace.view(hit))")
    return hit
  }

  override func flashScrollers() {
    // Do nothing to prevent flashing
  }
}

/// Keep the native viewport and scroller full-width. Center the narrower table
/// in document coordinates, including programmatic scrolls that request x = 0.
private final class CenteredMessageClipView: NSClipView {
  var maximumDocumentWidth: CGFloat? {
    didSet { recenterDocument() }
  }

  private func horizontalOrigin(for width: CGFloat) -> CGFloat {
    guard let maximumDocumentWidth else { return 0 }
    return -max(0, (width - maximumDocumentWidth) / 2)
  }

  func recenterDocument() {
    let x = horizontalOrigin(for: bounds.width)
    if bounds.origin.x != x {
      super.setBoundsOrigin(NSPoint(x: x, y: bounds.origin.y))
    }
  }

  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var constrained = super.constrainBoundsRect(proposedBounds)
    if maximumDocumentWidth != nil {
      constrained.origin.x = horizontalOrigin(for: proposedBounds.width)
    }
    return constrained
  }

  override func setBoundsOrigin(_ newOrigin: NSPoint) {
    var origin = newOrigin
    if maximumDocumentWidth != nil {
      origin.x = horizontalOrigin(for: bounds.width)
    }
    super.setBoundsOrigin(origin)
  }

  override func scroll(to newOrigin: NSPoint) {
    var origin = newOrigin
    if maximumDocumentWidth != nil {
      origin.x = horizontalOrigin(for: bounds.width)
    }
    super.scroll(to: origin)
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
