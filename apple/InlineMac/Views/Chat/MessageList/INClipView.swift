import AppKit

extension NSClipView {
  func updateBounds(_ point: NSPoint, cancel: Bool = false) {
    if bounds.origin != point {
      if cancel {
        CATransaction.begin()
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        animator().scroll(to: point)
        animator().setBoundsOrigin(point)
        NSAnimationContext.endGrouping()
        CATransaction.commit()
      } else {
        scroll(to: point)
      }
    }
  }
}
