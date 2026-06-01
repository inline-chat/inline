import AppKit

final class MessageSenderNameLabel: NSTextField {
  init() {
    super.init(frame: .zero)

    isEditable = false
    isBordered = false
    drawsBackground = false
    isSelectable = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }
}
