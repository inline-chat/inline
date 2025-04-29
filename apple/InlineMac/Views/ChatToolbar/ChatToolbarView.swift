import AppKit
import Logger

class ChatToolbarView: NSVisualEffectView {
  private var dependencies: AppDependencies
  private var log = Log.scoped("ChatToolbarView")

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    super.init(frame: .zero)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    blendingMode = .withinWindow
    state = .active
    material = .headerView
    translatesAutoresizingMaskIntoConstraints = false

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.1)
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.shadowBlurRadius = 0
    self.shadow = shadow
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
  }

  private func doubleClickAction() {
    let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"

    switch action {
      case "Minimize":
        window?.performMiniaturize(nil)

      default:
        window?.performZoom(nil)
    }
  }

  override func mouseDown(with event: NSEvent) {
    // Forward to window's title bar handling
    window?.performDrag(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if event.clickCount == 2 {
      doubleClickAction()
    }
  }
}
