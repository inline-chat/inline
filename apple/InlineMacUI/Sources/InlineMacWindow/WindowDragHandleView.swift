import AppKit

open class WindowDragHandleView: NSView {
  public var isDragEnabled = true

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
  }

  public required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  open override var mouseDownCanMoveWindow: Bool {
    false
  }

  public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  public override func mouseDown(with event: NSEvent) {
    guard isDragEnabled else {
      super.mouseDown(with: event)
      return
    }
    window?.beginWindowDrag(with: event)
  }

  public override func mouseUp(with event: NSEvent) {
    guard isDragEnabled else {
      super.mouseUp(with: event)
      return
    }

    if event.clickCount == 2 {
      handleDoubleClick()
      return
    }

    super.mouseUp(with: event)
  }

  private func handleDoubleClick() {
    let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
    if action == "Minimize" {
      window?.performMiniaturize(nil)
    } else {
      window?.performZoom(nil)
    }
  }
}

public extension NSWindow {
  func beginWindowDrag(with event: NSEvent) {
    let selector = NSSelectorFromString("performWindowDragWithEvent:")
    if responds(to: selector) {
      perform(selector, with: event)
    }
  }
}
