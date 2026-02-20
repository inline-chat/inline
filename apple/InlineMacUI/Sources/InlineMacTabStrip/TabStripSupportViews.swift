import AppKit

@MainActor
protocol TabStripItemHoverDelegate: AnyObject {
  func tabHoverDidChange(isHovered: Bool)
}

final class TabStripItemView: NSView {
  weak var hoverDelegate: TabStripItemHoverDelegate?
  var onAppearanceChanged: (() -> Void)?
  var onCloseRequest: (() -> Void)?
  var isClosable: Bool = true

  private var trackingArea: NSTrackingArea?

  override var mouseDownCanMoveWindow: Bool { false }

  override func menu(for _: NSEvent) -> NSMenu? {
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
    guard !mouseIsInsideView() else { return }
    hoverDelegate?.tabHoverDidChange(isHovered: false)
  }
}

final class TabStripNonDraggableTextField: NSTextField {
  override var mouseDownCanMoveWindow: Bool { false }
}

final class TabStripNonDraggableButton: NSButton {
  override var mouseDownCanMoveWindow: Bool { false }
}

final class TabStripNonDraggableImageView: NSImageView {
  override var mouseDownCanMoveWindow: Bool { false }
}
