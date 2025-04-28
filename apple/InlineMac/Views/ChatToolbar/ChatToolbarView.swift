import AppKit

class ChatToolbarView: NSVisualEffectView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupView()
    installDoubleClickHandler()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
//
//  override var mouseDownCanMoveWindow: Bool {
//    false
//  }

  private func setupView() {
    blendingMode = .withinWindow
    state = .active
    material = .headerView
    translatesAutoresizingMaskIntoConstraints = false

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.1)
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.shadowBlurRadius = 2
    self.shadow = shadow
  }

  private func installDoubleClickHandler() {
//    let recognizer = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
//    recognizer.numberOfClicksRequired = 2
//    addGestureRecognizer(recognizer)
  }

  @objc private func handleDoubleClick(_ sender: NSClickGestureRecognizer) {
    print("i am triggered")
    guard sender.state == .ended,
          let window,
          !window.styleMask.contains(.fullScreen) else { return }

    let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"

    switch action {
      case "Minimize":
        window.performMiniaturize(nil)

      default:
        window.performZoom(nil)
    }
  }
}
