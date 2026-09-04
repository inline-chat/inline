import AppKit

@MainActor
final class LoggingOutWindowController: NSWindowController {
  private static var shared: LoggingOutWindowController?
  private let label: NSTextField
  private let quitButton: NSButton

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

  static func showRecoveryRequired() {
    if shared == nil { show() }
    shared?.showRecoveryRequired()
  }

  private init() {
    let panel = LogoutPanel(
      contentRect: NSRect(x: 0, y: 0, width: 180, height: 70),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    label = NSTextField(labelWithString: "Logging out…")
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.alignment = .center
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setAccessibilityLabel("Logging out")

    quitButton = NSButton(title: "Quit Inline", target: nil, action: nil)
    quitButton.bezelStyle = .rounded
    quitButton.isHidden = true
    quitButton.translatesAutoresizingMaskIntoConstraints = false

    super.init(window: panel)

    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.level = .modalPanel
    panel.hasShadow = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    quitButton.target = self
    quitButton.action = #selector(quitInline)

    let contentView = NSVisualEffectView()
    contentView.material = .popover
    contentView.blendingMode = .behindWindow
    contentView.state = .active
    contentView.wantsLayer = true
    contentView.layer?.cornerRadius = 16
    contentView.layer?.masksToBounds = true
    contentView.addSubview(label)
    contentView.addSubview(quitButton)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      label.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
      label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
      quitButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      quitButton.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
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

  private func showRecoveryRequired() {
    guard let window else { return }
    label.stringValue =
      "Inline couldn’t finish logging out. Quit and reopen Inline to complete recovery safely."
    label.maximumNumberOfLines = 3
    label.lineBreakMode = .byWordWrapping
    label.setAccessibilityLabel(
      "Inline couldn’t finish logging out. Quit and reopen Inline to complete recovery safely."
    )
    quitButton.isHidden = false
    window.setContentSize(NSSize(width: 380, height: 150))
    window.center()
    window.makeKeyAndOrderFront(nil)
  }

  @objc private func quitInline() {
    NSApp.terminate(nil)
  }
}

private final class LogoutPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}
