import AppKit

// Custom NSTextView subclass to handle hit testing
class MessageTextView: NSTextView {
  override func resignFirstResponder() -> Bool {
    // Clear out selection when user clicks somewhere else
    selectedRanges = [NSValue(range: NSRange(location: 0, length: 0))]
    
    return super.resignFirstResponder()
  }
  
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return false
  }
  
  override func hitTest(_ point: NSPoint) -> NSView? {
    // Prevent hit testing when window is inactive
    guard let window = window, window.isKeyWindow else {
      return nil
    }
    return super.hitTest(point)
  }
  
  override func mouseDown(with event: NSEvent) {
    // Ensure window is key before handling mouse events
    guard let window = window else {
      super.mouseDown(with: event)
      return
    }
    
    if !window.isKeyWindow {
      window.makeKeyAndOrderFront(nil)
      // Optionally, you can choose to not forward the event
      return
    }
    
    super.mouseDown(with: event)
  }
}
