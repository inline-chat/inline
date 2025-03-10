import AppKit

class ChatDropView: NSView {
  var dropHandler: ((NSDraggingInfo) -> Bool)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([
      .fileURL,
      .tiff,
      .png,
      NSPasteboard.PasteboardType("public.image"),
      NSPasteboard.PasteboardType("public.file-url"),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    checkForValidDraggedItems(sender) ? .copy : []
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    // Visual feedback could go here
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    dropHandler?(sender) ?? false
  }

  private func checkForValidDraggedItems(_ sender: NSDraggingInfo) -> Bool {
    // Check for files
    if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self, NSImage.self], options: nil) {
      return true
    }

    // Check for images
    if sender.draggingPasteboard.data(forType: .tiff) != nil ||
      sender.draggingPasteboard.data(forType: .png) != nil
    {
      return true
    }

    return false
  }
}
