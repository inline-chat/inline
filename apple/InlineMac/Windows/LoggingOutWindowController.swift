import AppKit

@MainActor
final class LoggingOutWindowController: NSWindowController {
  private static var shared: LoggingOutWindowController?

  static func show() {
    guard shared == nil else { return }
    let controller = LoggingOutWindowController()
    shared = controller
    controller.showWindow(nil)
  }

  static func dismiss() {
    shared?.close()
    shared = nil
  }

  private init() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 164, height: 54),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    super.init(window: panel)

    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.level = .modalPanel
    panel.hasShadow = true
    panel.backgroundColor = .windowBackgroundColor
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let label = NSTextField(labelWithString: "Logging out…")
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setAccessibilityLabel("Logging out")

    let contentView = NSView()
    contentView.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
      label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
    ])
    panel.contentView = contentView
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func showWindow(_ sender: Any?) {
    guard let window else { return }
    if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
      let origin = NSPoint(
        x: parent.frame.midX - window.frame.width / 2,
        y: parent.frame.midY - window.frame.height / 2
      )
      window.setFrameOrigin(origin)
    } else {
      window.center()
    }
    super.showWindow(sender)
    window.orderFrontRegardless()
  }
}
