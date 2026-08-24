import AppKit
import InlineMacUI

class ChatDropView: NSView {
  var dropHandler: ((NSDraggingInfo) -> Bool)?
  var surfaceStyle: ChatViewAppearance.SurfaceStyle = .content {
    didSet { updateSurfaceBackgroundColor() }
  }

  override var wantsUpdateLayer: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    identifier = LocalDragSurfaceGuard.chatSurfaceIdentifier
    registerForDraggedTypes(InlinePasteboard.draggedTypes)
    updateSurfaceBackgroundColor()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateSurfaceBackgroundColor()
  }

  override func updateLayer() {
    super.updateLayer()
    updateSurfaceBackgroundColor()
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    checkForValidDraggedItems(sender) ? .copy : []
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    checkForValidDraggedItems(sender) ? .copy : []
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    // Visual feedback could go here
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard checkForValidDraggedItems(sender) else { return false }
    return dropHandler?(sender) ?? false
  }

  private func checkForValidDraggedItems(_ sender: NSDraggingInfo) -> Bool {
    if LocalDragSurfaceGuard.isDragFromSameSurface(source: sender.draggingSource, destinationView: self) {
      return false
    }

    return InlinePasteboard.canImportAttachments(
      from: sender.draggingPasteboard,
      includeText: false
    )
  }

  private func updateSurfaceBackgroundColor() {
    layer?.backgroundColor = surfaceStyle.backgroundColor
      .resolvedColor(with: effectiveAppearance)
      .cgColor
  }
}

extension ChatDropView: AppThemeRefreshable {
  func refreshAppTheme() {
    updateSurfaceBackgroundColor()
  }
}
