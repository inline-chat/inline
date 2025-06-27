import AppKit

/// A text field that is not interactive.
/// This is used to show a placeholder in the text field.
/// It is not editable, selectable, or enabled.
class NonInteractiveTextField: NSTextField {
  // MARK: - Lifecycle

  init(label: String) {
    super.init(frame: .zero)
    stringValue = label
    isEditable = false
    isSelectable = false
    isEnabled = false
    isBordered = false
    isBezeled = false
    drawsBackground = false
    allowsCharacterPickerTouchBarItem = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func mouseDown(with event: NSEvent) {
    // Pass the event to the superview
    superview?.mouseDown(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    // Pass the event to the superview
    superview?.mouseUp(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    // Pass the event to the superview
    superview?.mouseDragged(with: event)
  }

  override func mouseEntered(with event: NSEvent) {
    // Pass the event to the superview
    superview?.mouseEntered(with: event)
  }

  override func mouseExited(with event: NSEvent) {
    // Pass the event to the superview
    superview?.mouseExited(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    // Pass the event to the superview
    superview?.rightMouseDown(with: event)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    false
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // Return nil to make this view transparent to hit testing
    nil
  }
}
