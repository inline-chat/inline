import AppKit

// MARK: - Helper Views

final class TabBarItemView: NSView {
  weak var hoverDelegate: TabBarItemHoverDelegate?
  var onAppearanceChanged: (() -> Void)?
  var onCloseRequest: (() -> Void)?
  var isClosable: Bool = true

  private var trackingArea: NSTrackingArea?

  override var mouseDownCanMoveWindow: Bool { false }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard isClosable else { return nil }

    let menu = NSMenu()
    let closeItem = NSMenuItem(
      title: "Close Tab",
      action: #selector(closeTabAction),
      keyEquivalent: "w"
    )
    closeItem.target = self
    menu.addItem(closeItem)
    return menu
  }

  @objc private func closeTabAction() {
    onCloseRequest?()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    onAppearanceChanged?()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()

    guard trackingArea == nil else { return }

    let options: NSTrackingArea.Options = [
      .mouseEnteredAndExited,
      .activeInKeyWindow,
      .inVisibleRect,
      .mouseMoved,
      .enabledDuringMouseDrag,
    ]

    let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  private func mouseIsInsideView() -> Bool {
    guard let window else { return false }
    let mouseInWindow = window.mouseLocationOutsideOfEventStream
    let mouseInLocal = convert(mouseInWindow, from: nil)
    return bounds.contains(mouseInLocal)
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    hoverDelegate?.tabHoverDidChange(isHovered: true)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    // Ignore spurious exits caused by tracking updates; only clear when the cursor truly left.
    guard !mouseIsInsideView() else { return }
    hoverDelegate?.tabHoverDidChange(isHovered: false)
  }
}

final class NonDraggableTextField: NSTextField {
  override var mouseDownCanMoveWindow: Bool { false }
}

final class NonDraggableButton: NSButton {
  override var mouseDownCanMoveWindow: Bool { false }
}

final class NonDraggableImageView: NSImageView {
  override var mouseDownCanMoveWindow: Bool { false }
}
